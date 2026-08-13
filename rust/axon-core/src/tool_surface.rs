use crate::JsonRpcError;
use serde_json::{Map, Value, json};
use std::collections::HashSet;
use std::sync::OnceLock;

const ARTIFACT_JSON: &str = include_str!("../../../schema/tool-surface-v1.json");
const INVALID_PARAMS: i64 = -32602;
const INTERNAL_ERROR: i64 = -32603;
const BACKENDS: &[&str] = &["swift", "mac", "windows", "linux"];
const TOOLS_CALL_PROTOCOL_PARAMS: &[&str] = &["_meta"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolBackend {
    Swift,
    Mac,
    Windows,
    Linux,
}

fn internal(message: &str) -> JsonRpcError {
    JsonRpcError {
        code: INTERNAL_ERROR,
        message: "Internal error: invalid embedded tool surface artifact".into(),
        data: Some(json!({"reason": message})),
    }
}

impl ToolBackend {
    fn key(self) -> &'static str {
        match self {
            Self::Swift => "swift",
            Self::Mac => "mac",
            Self::Windows => "windows",
            Self::Linux => "linux",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ValidatedToolCall {
    pub name: String,
    pub socket_method: String,
    pub arguments: Value,
}

fn artifact() -> Result<&'static Value, JsonRpcError> {
    static ARTIFACT: OnceLock<Result<Value, String>> = OnceLock::new();
    ARTIFACT
        .get_or_init(|| parse_artifact(ARTIFACT_JSON))
        .as_ref()
        .map_err(|message| internal(message))
}

fn parse_artifact(source: &str) -> Result<Value, String> {
    let value: Value = serde_json::from_str(source)
        .map_err(|error| format!("invalid tool surface artifact: {error}"))?;
    let root = value
        .as_object()
        .ok_or_else(|| "tool surface artifact must be an object".to_string())?;
    if root.get("formatVersion") != Some(&json!(1)) {
        return Err("unsupported tool surface formatVersion".into());
    }
    let tools = root
        .get("tools")
        .and_then(Value::as_array)
        .ok_or_else(|| "tool surface tools must be an array".to_string())?;
    let mut names = HashSet::new();
    for (index, tool) in tools.iter().enumerate() {
        let path = format!("tools[{index}]");
        let tool = tool
            .as_object()
            .ok_or_else(|| format!("{path} must be an object"))?;
        let name = required_nonempty_string(tool, "name", &path)?;
        if !names.insert(name) {
            return Err(format!("duplicate tool name {name:?}"));
        }
        required_string(tool, "description", &path)?;
        required_nonempty_string(tool, "socketMethod", &path)?;
        let availability = tool
            .get("availability")
            .and_then(Value::as_object)
            .ok_or_else(|| format!("{path}.availability must be an object"))?;
        if availability.len() != BACKENDS.len() {
            return Err(format!(
                "{path}.availability must contain exactly swift, mac, windows, and linux"
            ));
        }
        for backend in BACKENDS {
            if !availability.get(*backend).is_some_and(Value::is_boolean) {
                return Err(format!("{path}.availability.{backend} must be a boolean"));
            }
        }
        let schema = tool
            .get("inputSchema")
            .ok_or_else(|| format!("{path} is missing inputSchema"))?;
        check_schema_vocabulary(schema, &format!("{path}.inputSchema"))?;
    }
    Ok(value)
}

fn required_string<'a>(
    object: &'a Map<String, Value>,
    key: &str,
    path: &str,
) -> Result<&'a str, String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{path}.{key} must be a string"))
}

fn required_nonempty_string<'a>(
    object: &'a Map<String, Value>,
    key: &str,
    path: &str,
) -> Result<&'a str, String> {
    let value = required_string(object, key, path)?;
    if value.is_empty() {
        Err(format!("{path}.{key} must not be empty"))
    } else {
        Ok(value)
    }
}

pub fn backend_tools(backend: ToolBackend) -> Result<Vec<Value>, JsonRpcError> {
    let tools = artifact()?
        .get("tools")
        .and_then(Value::as_array)
        .ok_or_else(|| internal("validated artifact lost tools array"))?;
    tools
        .iter()
        .filter(|tool| available(tool, backend))
        .map(|tool| {
            let mut entry = tool
                .as_object()
                .ok_or_else(|| internal("validated artifact contains a non-object tool"))?
                .clone();
            entry.remove("availability");
            entry.remove("socketMethod");
            Ok(Value::Object(entry))
        })
        .collect()
}

pub fn validate_tool_arguments(
    backend: ToolBackend,
    name: &str,
    arguments: Value,
) -> Result<Value, JsonRpcError> {
    let tool = find_tool(artifact()?, backend, name)?;
    validate_tool_arguments_for(tool, arguments)
}

fn validate_tool_arguments_for(tool: &Value, arguments: Value) -> Result<Value, JsonRpcError> {
    if !arguments.is_object() {
        return Err(invalid(
            "params.arguments",
            "expected object",
            Some("object"),
        ));
    }
    let mut normalized = arguments;
    validate_value(&tool["inputSchema"], &normalized, "params.arguments")?;
    apply_defaults(&tool["inputSchema"], &mut normalized);
    Ok(normalized)
}

pub fn validate_tools_call(
    backend: ToolBackend,
    params: Option<Value>,
) -> Result<ValidatedToolCall, JsonRpcError> {
    validate_tools_call_from(artifact()?, backend, params)
}

pub fn validate_tools_call_from_artifact(
    source: &str,
    backend: ToolBackend,
    params: Option<Value>,
) -> Result<ValidatedToolCall, JsonRpcError> {
    let artifact = parse_artifact(source).map_err(|message| internal(&message))?;
    validate_tools_call_from(&artifact, backend, params)
}

fn validate_tools_call_from(
    artifact: &Value,
    backend: ToolBackend,
    params: Option<Value>,
) -> Result<ValidatedToolCall, JsonRpcError> {
    let params =
        params.ok_or_else(|| invalid("params", "missing required object", Some("object")))?;
    let object = params
        .as_object()
        .ok_or_else(|| invalid("params", "expected object", Some("object")))?;
    for key in object.keys() {
        if key != "name"
            && key != "arguments"
            && !TOOLS_CALL_PROTOCOL_PARAMS.contains(&key.as_str())
        {
            return Err(invalid(&format!("params.{key}"), "unknown field", None));
        }
    }
    let name = object
        .get("name")
        .ok_or_else(|| invalid("params.name", "missing required field", Some("string")))?
        .as_str()
        .ok_or_else(|| invalid("params.name", "expected string", Some("string")))?;
    let arguments = object
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| Value::Object(Map::new()));
    let tool = find_tool(artifact, backend, name)?;
    Ok(ValidatedToolCall {
        name: name.to_string(),
        socket_method: tool["socketMethod"]
            .as_str()
            .ok_or_else(|| internal("validated artifact lost socketMethod"))?
            .to_string(),
        arguments: validate_tool_arguments_for(tool, arguments)?,
    })
}

fn find_tool<'a>(
    artifact: &'a Value,
    backend: ToolBackend,
    name: &str,
) -> Result<&'a Value, JsonRpcError> {
    artifact
        .get("tools")
        .and_then(Value::as_array)
        .ok_or_else(|| internal("validated artifact lost tools array"))?
        .iter()
        .find(|tool| tool["name"].as_str() == Some(name) && available(tool, backend))
        .ok_or_else(|| {
            invalid(
                "params.name",
                &format!("unknown or unavailable tool {name:?}"),
                None,
            )
        })
}

fn available(tool: &Value, backend: ToolBackend) -> bool {
    tool["availability"][backend.key()].as_bool() == Some(true)
}

fn check_schema_vocabulary(schema: &Value, path: &str) -> Result<(), String> {
    let object = schema
        .as_object()
        .ok_or_else(|| format!("{path} must be an object"))?;
    const ALLOWED: &[&str] = &[
        "type",
        "description",
        "default",
        "properties",
        "required",
        "additionalProperties",
        "anyOf",
        "oneOf",
        "items",
        "enum",
        "minimum",
    ];
    for key in object.keys() {
        if !ALLOWED.contains(&key.as_str()) {
            return Err(format!("unsupported schema keyword {path}.{key}"));
        }
    }
    if let Some(description) = object.get("description")
        && !description.is_string()
    {
        return Err(format!("{path}.description must be a string"));
    }
    if let Some(schema_type) = object.get("type") {
        let schema_type = schema_type
            .as_str()
            .ok_or_else(|| format!("{path}.type must be a string"))?;
        if !["object", "array", "string", "boolean", "integer", "number"].contains(&schema_type) {
            return Err(format!("{path}.type has unsupported value {schema_type:?}"));
        }
    }
    let properties = object
        .get("properties")
        .map(|value| {
            value
                .as_object()
                .ok_or_else(|| format!("{path}.properties must be an object"))
        })
        .transpose()?;
    if let Some(properties) = properties {
        for (name, child) in properties {
            check_schema_vocabulary(child, &format!("{path}.properties.{name}"))?;
        }
    }
    if let Some(items) = object.get("items") {
        check_schema_vocabulary(items, &format!("{path}.items"))?;
    }
    if let Some(required) = object.get("required") {
        let required = required
            .as_array()
            .ok_or_else(|| format!("{path}.required must be an array"))?;
        let mut names = HashSet::new();
        for (index, name) in required.iter().enumerate() {
            let name = name
                .as_str()
                .ok_or_else(|| format!("{path}.required[{index}] must be a string"))?;
            if !names.insert(name) {
                return Err(format!("{path}.required contains duplicate {name:?}"));
            }
        }
    }
    if let Some(additional) = object.get("additionalProperties")
        && !additional.is_boolean()
    {
        return Err(format!("{path}.additionalProperties must be a boolean"));
    }
    for keyword in ["anyOf", "oneOf"] {
        if let Some(branches) = object.get(keyword) {
            let branches = branches
                .as_array()
                .ok_or_else(|| format!("{path}.{keyword} must be an array"))?;
            if branches.is_empty() {
                return Err(format!("{path}.{keyword} must not be empty"));
            }
            for (index, branch) in branches.iter().enumerate() {
                check_schema_vocabulary(branch, &format!("{path}.{keyword}[{index}]"))?;
            }
        }
    }
    if let Some(allowed) = object.get("enum") {
        let allowed = allowed
            .as_array()
            .ok_or_else(|| format!("{path}.enum must be an array"))?;
        if allowed.is_empty() {
            return Err(format!("{path}.enum must not be empty"));
        }
        for (index, value) in allowed.iter().enumerate() {
            if allowed[..index].contains(value) {
                return Err(format!("{path}.enum contains duplicate values"));
            }
            validate_value(schema, value, path)
                .map_err(|error| format!("{path}.enum[{index}] is invalid: {}", error.message))?;
        }
    }
    let object_only = ["properties", "required", "additionalProperties"];
    if object_only
        .iter()
        .any(|keyword| object.contains_key(*keyword))
        && object
            .get("type")
            .and_then(Value::as_str)
            .is_some_and(|value| value != "object")
    {
        return Err(format!("{path} uses object keywords without type object"));
    }
    if object.contains_key("items")
        && object
            .get("type")
            .and_then(Value::as_str)
            .is_some_and(|value| value != "array")
    {
        return Err(format!("{path}.items requires type array"));
    }
    if let Some(default) = object.get("default") {
        validate_value(schema, default, path)
            .map_err(|error| format!("{path}.default is invalid: {}", error.message))?;
    }
    if let Some(minimum) = object.get("minimum") {
        if !minimum.is_number() {
            return Err(format!("{path}.minimum must be a number"));
        }
        if !matches!(
            object.get("type").and_then(Value::as_str),
            Some("integer" | "number")
        ) {
            return Err(format!("{path}.minimum requires a numeric type"));
        }
    }
    Ok(())
}

fn validate_value(schema: &Value, value: &Value, path: &str) -> Result<(), JsonRpcError> {
    if let Some(allowed) = schema.get("enum").and_then(Value::as_array)
        && !allowed.contains(value)
    {
        return Err(invalid(path, "value is not in the allowed enum", None));
    }
    if let Some(branches) = schema.get("anyOf").and_then(Value::as_array) {
        validate_branches(branches, value, path, false)?;
    }
    if let Some(branches) = schema.get("oneOf").and_then(Value::as_array) {
        validate_branches(branches, value, path, true)?;
    }
    let expected = schema.get("type").and_then(Value::as_str);
    let type_matches = match expected {
        None => true,
        Some("object") => value.is_object(),
        Some("array") => value.is_array(),
        Some("string") => value.is_string(),
        Some("boolean") => value.is_boolean(),
        Some("integer") => value.as_i64().is_some() || value.as_u64().is_some(),
        Some("number") => value.is_number(),
        Some(other) => {
            return Err(invalid(
                path,
                &format!("unsupported schema type {other}"),
                None,
            ));
        }
    };
    if !type_matches {
        return Err(invalid(
            path,
            &format!("expected {}", expected.unwrap()),
            expected,
        ));
    }
    if let (Some(minimum), Some(number)) = (
        schema.get("minimum").and_then(Value::as_f64),
        value.as_f64(),
    ) && number < minimum
    {
        return Err(invalid(
            path,
            &format!("must be at least {minimum}"),
            expected,
        ));
    }
    if let Some(object) = value.as_object() {
        validate_object(schema, object, path)?;
    }
    if let (Some(items), Some(values)) = (schema.get("items"), value.as_array()) {
        for (index, item) in values.iter().enumerate() {
            validate_value(items, item, &format!("{path}[{index}]"))?;
        }
    }
    Ok(())
}

fn validate_object(
    schema: &Value,
    object: &Map<String, Value>,
    path: &str,
) -> Result<(), JsonRpcError> {
    let properties = schema.get("properties").and_then(Value::as_object);
    if let Some(required) = schema.get("required").and_then(Value::as_array) {
        for name in required.iter().filter_map(Value::as_str) {
            if !object.contains_key(name) {
                return Err(invalid(
                    &format!("{path}.{name}"),
                    "missing required field",
                    None,
                ));
            }
        }
    }
    if schema.get("additionalProperties").and_then(Value::as_bool) == Some(false) {
        let known: HashSet<&str> = properties
            .into_iter()
            .flat_map(|entries| entries.keys().map(String::as_str))
            .collect();
        for name in object.keys() {
            if !known.contains(name.as_str()) {
                return Err(invalid(&format!("{path}.{name}"), "unknown field", None));
            }
        }
    }
    if let Some(properties) = properties {
        for (name, child_schema) in properties {
            if let Some(child) = object.get(name) {
                validate_value(child_schema, child, &format!("{path}.{name}"))?;
            }
        }
    }
    Ok(())
}

fn validate_branches(
    branches: &[Value],
    value: &Value,
    path: &str,
    exactly_one: bool,
) -> Result<(), JsonRpcError> {
    let results: Vec<_> = branches
        .iter()
        .map(|branch| validate_value(branch, value, path))
        .collect();
    let successes = results.iter().filter(|result| result.is_ok()).count();
    if successes == 0 {
        if !exactly_one
            && let Some(error) = branches
                .iter()
                .zip(results)
                .filter_map(|(branch, result)| {
                    result.err().map(|error| {
                        let recognized = value.as_object().map_or(0, |object| {
                            branch.get("properties").and_then(Value::as_object).map_or(
                                0,
                                |properties| {
                                    object
                                        .keys()
                                        .filter(|key| properties.contains_key(*key))
                                        .count()
                                },
                            )
                        });
                        let path_length = error
                            .data
                            .as_ref()
                            .and_then(|data| data["path"].as_str())
                            .map_or(0, str::len);
                        ((recognized, path_length), error)
                    })
                })
                .max_by_key(|(score, _)| *score)
                .map(|(_, error)| error)
        {
            return Err(error);
        }
        return Err(invalid(path, "did not match any schema alternative", None));
    }
    if exactly_one && successes != 1 {
        return Err(invalid(
            path,
            "expected exactly one schema alternative",
            None,
        ));
    }
    Ok(())
}

fn apply_defaults(schema: &Value, value: &mut Value) {
    if let (Some(properties), Some(object)) = (
        schema.get("properties").and_then(Value::as_object),
        value.as_object_mut(),
    ) {
        for (name, child_schema) in properties {
            if !object.contains_key(name)
                && let Some(default) = child_schema.get("default")
            {
                object.insert(name.clone(), default.clone());
            }
            if let Some(child) = object.get_mut(name) {
                apply_defaults(child_schema, child);
            }
        }
    }
    if let (Some(items), Some(values)) = (schema.get("items"), value.as_array_mut()) {
        for item in values {
            apply_defaults(items, item);
        }
    }
    for keyword in ["anyOf", "oneOf"] {
        if let Some(branch) = schema
            .get(keyword)
            .and_then(Value::as_array)
            .and_then(|branches| {
                branches
                    .iter()
                    .find(|branch| validate_value(branch, value, "default").is_ok())
            })
        {
            apply_defaults(branch, value);
        }
    }
}

fn invalid(path: &str, message: &str, expected: Option<&str>) -> JsonRpcError {
    JsonRpcError {
        code: INVALID_PARAMS,
        message: format!("Invalid params at {path}: {message}"),
        data: Some(json!({
            "path": path,
            "expected": expected,
            "reason": message,
        })),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_artifact(schema: Value) -> Value {
        json!({
            "formatVersion": 1,
            "tools": [{
                "name": "test",
                "description": "Test tool",
                "socketMethod": "test",
                "availability": {
                    "swift": true, "mac": true, "windows": false, "linux": false
                },
                "inputSchema": schema
            }]
        })
    }

    fn parse_value(value: &Value) -> Result<Value, String> {
        parse_artifact(&serde_json::to_string(value).unwrap())
    }

    fn names(backend: ToolBackend) -> Vec<String> {
        backend_tools(backend)
            .unwrap()
            .iter()
            .map(|tool| tool["name"].as_str().unwrap().to_string())
            .collect()
    }

    #[test]
    fn backend_tool_sets_are_ordered() {
        assert_eq!(
            names(ToolBackend::Mac),
            [
                "look",
                "find",
                "wait_for_value",
                "wait_for_stability",
                "run",
                "click",
                "type",
                "keyboard",
                "scroll",
                "invoke"
            ]
        );
        assert_eq!(
            names(ToolBackend::Windows),
            [
                "look", "find", "run", "click", "type", "keyboard", "scroll", "invoke"
            ]
        );
        assert_eq!(
            names(ToolBackend::Linux),
            [
                "look", "find", "run", "click", "type", "keyboard", "scroll", "invoke"
            ]
        );
    }

    #[test]
    fn validates_before_applying_defaults() {
        let value = validate_tool_arguments(ToolBackend::Linux, "look", json!({})).unwrap();
        assert_eq!(value["screenshot"], true);
        assert_eq!(value["offset"], 0);
        assert_eq!(value["frames"], false);
        let error =
            validate_tool_arguments(ToolBackend::Linux, "look", json!({"screenshot": "false"}))
                .unwrap_err();
        assert_eq!(error.code, -32602);
        assert_eq!(error.data.unwrap()["path"], "params.arguments.screenshot");
    }

    #[test]
    fn rejects_wrong_integer_and_unknown_fields() {
        let error =
            validate_tool_arguments(ToolBackend::Mac, "look", json!({"depth": "2"})).unwrap_err();
        assert_eq!(error.data.unwrap()["path"], "params.arguments.depth");
        let error =
            validate_tool_arguments(ToolBackend::Mac, "look", json!({"bogus": true})).unwrap_err();
        assert_eq!(error.data.unwrap()["path"], "params.arguments.bogus");
    }

    #[test]
    fn rejects_missing_and_malformed_nested_targets() {
        let error = validate_tool_arguments(ToolBackend::Windows, "click", json!({})).unwrap_err();
        assert_eq!(error.data.unwrap()["path"], "params.arguments.target");
        let error = validate_tool_arguments(
            ToolBackend::Windows,
            "type",
            json!({
                "target": {"app": 42, "name": "Field"}, "value": "x"
            }),
        )
        .unwrap_err();
        assert_eq!(error.data.unwrap()["path"], "params.arguments.target.app");
        let error = validate_tool_arguments(
            ToolBackend::Windows,
            "type",
            json!({
                "target": {"app": "Notes"}, "value": "x"
            }),
        )
        .unwrap_err();
        assert_eq!(error.data.unwrap()["path"], "params.arguments.target.name");
    }

    #[test]
    fn enforces_cross_field_alternatives_after_property_validation() {
        let normalized =
            validate_tool_arguments(ToolBackend::Windows, "keyboard", json!({"text": "hello"}))
                .unwrap();
        assert_eq!(normalized["deliveryPolicy"], "backgroundOnly");

        for arguments in [json!({}), json!({"text": "x", "key": "Return"})] {
            let error =
                validate_tool_arguments(ToolBackend::Windows, "keyboard", arguments).unwrap_err();
            assert_eq!(error.code, -32602);
            assert_eq!(error.data.unwrap()["path"], "params.arguments");
        }

        let error =
            validate_tool_arguments(ToolBackend::Windows, "keyboard", json!({"text": false}))
                .unwrap_err();
        assert_eq!(error.data.unwrap()["path"], "params.arguments.text");
    }

    #[test]
    fn applies_defaults_inside_the_matching_composed_schema_branch() {
        let target = json!({
            "location": {
                "app": "Notes",
                "text": {"contains": "Save"}
            }
        });
        let normalized =
            validate_tool_arguments(ToolBackend::Windows, "click", json!({"target": target}))
                .unwrap();

        assert_eq!(
            normalized["target"],
            json!({
                "location": {
                    "app": "Notes",
                    "text": {"contains": "Save", "caseSensitive": false},
                    "source": "auto"
                }
            })
        );
        assert_eq!(normalized["deliveryPolicy"], "backgroundOnly");
    }

    #[test]
    fn any_of_reports_the_branch_matching_the_callers_object_shape() {
        let error = validate_tool_arguments(
            ToolBackend::Windows,
            "click",
            json!({"target":{"app":"Notes","name":"Save","bogus":true}}),
        )
        .unwrap_err();
        assert_eq!(error.data.unwrap()["path"], "params.arguments.target.bogus");
    }

    #[test]
    fn rejects_flat_target_shorthand_and_bad_call_params() {
        let error = validate_tool_arguments(
            ToolBackend::Windows,
            "click",
            json!({
                "app": "Notes", "name": "Save"
            }),
        )
        .unwrap_err();
        assert!(
            error.message.contains("params.arguments.target")
                || error.message.contains("params.arguments.app")
        );
        let error = validate_tools_call(ToolBackend::Linux, Some(json!({"name": 3}))).unwrap_err();
        assert_eq!(error.data.unwrap()["path"], "params.name");
    }

    #[test]
    fn accepts_protocol_metadata_without_treating_it_as_tool_arguments() {
        let call = validate_tools_call(
            ToolBackend::Linux,
            Some(json!({
                "name": "look",
                "arguments": {},
                "_meta": {"progressToken": "p1"}
            })),
        )
        .unwrap();

        assert!(call.arguments.get("_meta").is_none());

        let error = validate_tools_call(
            ToolBackend::Linux,
            Some(json!({
                "name": "look",
                "arguments": {"bogus": true},
                "_meta": {"progressToken": "p1"}
            })),
        )
        .unwrap_err();
        assert_eq!(error.data.unwrap()["path"], "params.arguments.bogus");
    }

    #[test]
    fn only_declared_protocol_fields_bypass_strict_call_envelope_validation() {
        for field in TOOLS_CALL_PROTOCOL_PARAMS {
            let mut params = json!({"name": "look", "arguments": {}});
            params
                .as_object_mut()
                .unwrap()
                .insert((*field).into(), json!({}));
            validate_tools_call(ToolBackend::Linux, Some(params)).unwrap();
        }

        let error = validate_tools_call(
            ToolBackend::Linux,
            Some(json!({"name": "look", "arguments": {}, "futureReservedField": {}})),
        )
        .unwrap_err();
        assert_eq!(error.data.unwrap()["path"], "params.futureReservedField");
    }

    #[test]
    fn rejects_malformed_supported_schema_keywords_at_initialization() {
        let malformed = [
            json!({"type": 3}),
            json!({"type": "object", "required": "name"}),
            json!({"type": "object", "required": ["name", 3]}),
            json!({"type": "object", "additionalProperties": "false"}),
            json!({"anyOf": {}}),
            json!({"oneOf": []}),
            json!({"type": "object", "properties": []}),
            json!({"type": "array", "items": []}),
            json!({"enum": "x"}),
            json!({"enum": []}),
            json!({"type": "string", "enum": [3]}),
            json!({"type": "string", "default": false}),
        ];
        for schema in malformed {
            assert!(
                parse_value(&test_artifact(schema.clone())).is_err(),
                "accepted malformed schema {schema}"
            );
        }
    }

    #[test]
    fn rejects_incompatible_schema_keyword_combinations() {
        for schema in [
            json!({"type": "string", "properties": {}}),
            json!({"type": "object", "items": {"type": "string"}}),
        ] {
            assert!(
                parse_value(&test_artifact(schema.clone())).is_err(),
                "accepted incompatible schema {schema}"
            );
        }
    }

    #[test]
    fn rejects_malformed_tool_envelopes_at_initialization() {
        let valid = test_artifact(json!({
            "type": "object",
            "properties": {},
            "additionalProperties": false
        }));
        let mut cases = vec![json!({"formatVersion": 1, "tools": [false]})];

        for (field, value) in [
            ("name", json!("")),
            ("name", json!(3)),
            ("description", json!(false)),
            ("socketMethod", json!(null)),
            ("inputSchema", json!([])),
        ] {
            let mut artifact = valid.clone();
            artifact["tools"][0][field] = value;
            cases.push(artifact);
        }
        let mut incomplete = valid.clone();
        incomplete["tools"][0]["availability"]
            .as_object_mut()
            .unwrap()
            .remove("linux");
        cases.push(incomplete);
        let mut non_boolean = valid.clone();
        non_boolean["tools"][0]["availability"]["linux"] = json!("false");
        cases.push(non_boolean);
        let mut duplicate = valid.clone();
        let second = duplicate["tools"][0].clone();
        duplicate["tools"].as_array_mut().unwrap().push(second);
        cases.push(duplicate);

        for artifact in cases {
            assert!(
                parse_value(&artifact).is_err(),
                "accepted malformed artifact {artifact}"
            );
        }
    }

    #[test]
    fn artifact_defects_use_internal_error_class() {
        let error = internal("bad artifact");
        assert_eq!(error.code, -32603);
        assert_eq!(error.data.unwrap()["reason"], "bad artifact");
    }

    #[test]
    fn resolves_socket_method_without_changing_public_lookup_name() {
        let mut synthetic = test_artifact(json!({
            "type": "object",
            "properties": {},
            "additionalProperties": false
        }));
        synthetic["tools"][0]["name"] = json!("public-name");
        synthetic["tools"][0]["socketMethod"] = json!("private.socket.method");
        synthetic["tools"][0]["availability"]["linux"] = json!(true);

        let call = validate_tools_call_from_artifact(
            &serde_json::to_string(&synthetic).unwrap(),
            ToolBackend::Linux,
            Some(json!({"name": "public-name", "arguments": {}})),
        )
        .unwrap();

        assert_eq!(call.name, "public-name");
        assert_eq!(call.socket_method, "private.socket.method");
        assert_eq!(call.arguments, json!({}));
    }
}
