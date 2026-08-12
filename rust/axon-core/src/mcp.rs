use serde_json::{Value, json};

/// Builds the canonical MCP tool result while moving image bytes out of structured content.
pub fn mcp_tool_result(mut structured_content: Value, is_error: bool) -> Value {
    let mut images = Vec::new();
    extract_images(&mut structured_content, &mut images);
    let text = serde_json::to_string(&structured_content).expect("JSON values serialize");
    let mut content = vec![json!({"type": "text", "text": text})];
    content.extend(images);
    json!({
        "content": content,
        "structuredContent": structured_content,
        "isError": is_error
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_observation_envelope_is_byte_exact() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../schema/fixtures/mcp-look-observation-envelope.json"
        ))
        .unwrap();
        let actual = mcp_tool_result(fixture["structuredContent"].clone(), false);
        assert_eq!(actual, fixture["result"]);
        assert_eq!(
            serde_json::to_string(&actual).unwrap(),
            serde_json::to_string(&fixture["result"]).unwrap()
        );
    }
}

fn extract_images(value: &mut Value, images: &mut Vec<Value>) {
    match value {
        Value::Object(object) => {
            if let (Some(Value::String(data)), Some(Value::String(media_type))) =
                (object.get("base64Data"), object.get("mediaType"))
            {
                images.push(json!({"type": "image", "data": data, "mimeType": media_type}));
                object.remove("base64Data");
                object.insert("contentTransport".into(), Value::String("mcp_image".into()));
            }
            for child in object.values_mut() {
                extract_images(child, images);
            }
        }
        Value::Array(values) => {
            for child in values {
                extract_images(child, images);
            }
        }
        _ => {}
    }
}