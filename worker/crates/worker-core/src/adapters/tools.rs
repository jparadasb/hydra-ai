//! Shared helpers for translating OpenAI-shaped tool definitions / calls into the wire
//! formats of providers that don't speak the OpenAI schema (Anthropic, Gemini, Responses).
//!
//! The normalized [`crate::types::ChatRequest`] carries tools exactly as an OpenAI client
//! sent them: `tools: [{"type":"function","function":{name,description,parameters}}]` and
//! `tool_choice: "auto" | "none" | "required" | {"type":"function","function":{"name":..}}`.

use serde_json::Value;

use crate::error::{Error, Result};
use crate::types::{ToolCall, ToolCallFunction};

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

/// Recover tool calls leaked as Qwen/llama.cpp markup in `message.content`. Native OpenAI
/// `tool_calls` should always win; call this only when that field is absent and tools were
/// offered. `Ok(None)` means the content contains no tool protocol marker.
pub(crate) fn normalize_tool_markup(
    content: &str,
    tools: &Value,
) -> Result<Option<(String, Vec<ToolCall>)>> {
    const OPEN: &str = "<tool_call>";
    const CLOSE: &str = "</tool_call>";

    if !content.contains(OPEN) {
        return Ok(None);
    }

    let allowed: Vec<&str> = function_defs(tools).into_iter().map(|f| f.name).collect();
    let mut rest = content;
    let mut plain = String::new();
    let mut calls = Vec::new();

    while let Some(start) = rest.find(OPEN) {
        plain.push_str(&rest[..start]);
        let body_start = start + OPEN.len();
        let after_open = &rest[body_start..];
        let Some(end) = after_open.find(CLOSE) else {
            return Err(protocol_error("missing </tool_call>"));
        };
        let body = after_open[..end].trim();
        let parsed = parse_tool_block(body)?;
        for (name, arguments) in parsed {
            if !allowed.iter().any(|candidate| *candidate == name) {
                return Err(protocol_error(&format!("unknown function '{name}'")));
            }
            calls.push(ToolCall {
                id: format!("call_{}", calls.len()),
                kind: "function".to_string(),
                function: ToolCallFunction { name, arguments },
            });
        }
        rest = &after_open[end + CLOSE.len()..];
    }
    plain.push_str(rest);

    if calls.is_empty() {
        return Err(protocol_error("tool marker contained no calls"));
    }
    Ok(Some((plain.trim().to_string(), calls)))
}

fn parse_tool_block(body: &str) -> Result<Vec<(String, String)>> {
    if body.starts_with('{') || body.starts_with('[') {
        let value: Value = serde_json::from_str(body)
            .map_err(|e| protocol_error(&format!("invalid JSON: {e}")))?;
        let items = match value {
            Value::Array(items) => items,
            item => vec![item],
        };
        return items.into_iter().map(parse_json_call).collect();
    }

    parse_tagged_calls(body)
}

fn parse_json_call(value: Value) -> Result<(String, String)> {
    let name = value
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| protocol_error("JSON call missing string name"))?
        .to_string();
    let arguments = value
        .get("arguments")
        .ok_or_else(|| protocol_error("JSON call missing arguments"))?;
    let arguments = match arguments {
        Value::String(encoded) => {
            serde_json::from_str::<Value>(encoded)
                .map_err(|e| protocol_error(&format!("invalid encoded arguments: {e}")))?;
            encoded.clone()
        }
        value => serde_json::to_string(value).map_err(Error::from)?,
    };
    Ok((name, arguments))
}

fn parse_tagged_calls(mut body: &str) -> Result<Vec<(String, String)>> {
    const FUNCTION_OPEN: &str = "<function=";
    const FUNCTION_CLOSE: &str = "</function>";
    const PARAM_OPEN: &str = "<parameter=";
    const PARAM_CLOSE: &str = "</parameter>";
    let mut calls = Vec::new();

    while let Some(start) = body.find(FUNCTION_OPEN) {
        let after = &body[start + FUNCTION_OPEN.len()..];
        let name_end = after
            .find('>')
            .ok_or_else(|| protocol_error("unterminated function tag"))?;
        let name = after[..name_end].trim().to_string();
        let function_body = &after[name_end + 1..];
        let end = function_body
            .find(FUNCTION_CLOSE)
            .ok_or_else(|| protocol_error("missing </function>"))?;
        let mut params = &function_body[..end];
        let mut arguments = serde_json::Map::new();

        while let Some(param_start) = params.find(PARAM_OPEN) {
            let after_param = &params[param_start + PARAM_OPEN.len()..];
            let key_end = after_param
                .find('>')
                .ok_or_else(|| protocol_error("unterminated parameter tag"))?;
            let key = after_param[..key_end].trim();
            let value_body = &after_param[key_end + 1..];
            let value_end = value_body
                .find(PARAM_CLOSE)
                .ok_or_else(|| protocol_error("missing </parameter>"))?;
            let raw = value_body[..value_end].trim();
            let value =
                serde_json::from_str(raw).unwrap_or_else(|_| Value::String(raw.to_string()));
            arguments.insert(key.to_string(), value);
            params = &value_body[value_end + PARAM_CLOSE.len()..];
        }

        calls.push((name, Value::Object(arguments).to_string()));
        body = &function_body[end + FUNCTION_CLOSE.len()..];
    }

    if calls.is_empty() {
        Err(protocol_error("unsupported tool-call markup"))
    } else {
        Ok(calls)
    }
}

fn protocol_error(detail: &str) -> Error {
    Error::Other(format!("malformed_tool_call: {detail}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tools() -> Value {
        json!([{"type":"function","function":{"name":"weather","parameters":{}}},
               {"type":"function","function":{"name":"write","parameters":{}}}])
    }

    #[test]
    fn parses_json_and_multiple_calls() {
        let raw = "preface <tool_call>[{\"name\":\"weather\",\"arguments\":{\"city\":\"Paris\"}},{\"name\":\"write\",\"arguments\":{\"rows\":[{\"x\":1}]}}]</tool_call>";
        let (plain, calls) = normalize_tool_markup(raw, &tools()).unwrap().unwrap();
        assert_eq!(plain, "preface");
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].id, "call_0");
        assert_eq!(calls[1].function.arguments, r#"{"rows":[{"x":1}]}"#);
    }

    #[test]
    fn parses_qwen_coder_tagged_arguments() {
        let raw = "<tool_call><function=write><parameter=path>\"a.txt\"</parameter><parameter=rows>[{\"x\":1}]</parameter></function></tool_call>";
        let (_, calls) = normalize_tool_markup(raw, &tools()).unwrap().unwrap();
        assert_eq!(calls[0].function.name, "write");
        assert_eq!(
            calls[0].function.arguments,
            r#"{"path":"a.txt","rows":[{"x":1}]}"#
        );
    }

    #[test]
    fn rejects_malformed_or_unknown_calls() {
        assert!(normalize_tool_markup("<tool_call>{bad}</tool_call>", &tools()).is_err());
        assert!(normalize_tool_markup(
            "<tool_call>{\"name\":\"nope\",\"arguments\":{}}</tool_call>",
            &tools()
        )
        .is_err());
    }
}
