//! Just enough JSON to speak to the coordinator.
//!
//! Serialization is a dependency this crate does not want: the whole point of
//! the probe being standalone is that re-running the campaign never needs a
//! registry. The output shapes here are small and fixed, so a writer is
//! cheaper than the isolation it would cost to import one.

use std::fmt::Write as _;

#[derive(Clone, Debug)]
pub enum J {
    Null,
    Bool(bool),
    Int(i64),
    Num(f64),
    Str(String),
    Arr(Vec<J>),
    Obj(Vec<(String, J)>),
}

impl J {
    pub fn str(value: impl Into<String>) -> J {
        J::Str(value.into())
    }

    pub fn obj(fields: Vec<(&str, J)>) -> J {
        J::Obj(
            fields
                .into_iter()
                .map(|(key, value)| (key.to_string(), value))
                .collect(),
        )
    }

    pub fn render(&self) -> String {
        let mut out = String::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut String) {
        match self {
            J::Null => out.push_str("null"),
            J::Bool(value) => out.push_str(if *value { "true" } else { "false" }),
            J::Int(value) => {
                let _ = write!(out, "{value}");
            }
            J::Num(value) => {
                if value.is_finite() {
                    let _ = write!(out, "{value}");
                } else {
                    out.push_str("null");
                }
            }
            J::Str(value) => write_string(value, out),
            J::Arr(items) => {
                out.push('[');
                for (index, item) in items.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    item.write(out);
                }
                out.push(']');
            }
            J::Obj(fields) => {
                out.push('{');
                for (index, (key, value)) in fields.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    write_string(key, out);
                    out.push(':');
                    value.write(out);
                }
                out.push('}');
            }
        }
    }
}

fn write_string(value: &str, out: &mut String) {
    out.push('"');
    for character in value.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            character if (character as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", character as u32);
            }
            character => out.push(character),
        }
    }
    out.push('"');
}
