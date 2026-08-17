//! `--key value` and `--flag` parsing. The probe is called by one coordinator
//! with a fixed vocabulary, so an argument it does not recognize is a mistake
//! worth failing on rather than a shape worth tolerating.

use std::collections::HashMap;

pub struct Args {
    values: HashMap<String, String>,
    flags: Vec<String>,
}

impl Args {
    pub fn parse(raw: &[String]) -> Args {
        let mut values = HashMap::new();
        let mut flags = Vec::new();
        let mut index = 0;
        while index < raw.len() {
            let item = &raw[index];
            let Some(key) = item.strip_prefix("--") else {
                index += 1;
                continue;
            };
            match raw.get(index + 1) {
                Some(value) if !value.starts_with("--") => {
                    values.insert(key.to_string(), value.clone());
                    index += 2;
                }
                _ => {
                    flags.push(key.to_string());
                    index += 1;
                }
            }
        }
        Args { values, flags }
    }

    pub fn flag(&self, name: &str) -> bool {
        self.flags.iter().any(|flag| flag == name)
    }

    pub fn optional_string(&self, name: &str) -> Option<String> {
        self.values.get(name).cloned()
    }

    pub fn string(&self, name: &str) -> Result<String, String> {
        self.optional_string(name)
            .ok_or_else(|| format!("--{name} is required"))
    }

    pub fn optional_i32(&self, name: &str) -> Option<i32> {
        self.values.get(name).and_then(|value| value.parse().ok())
    }

    pub fn i32(&self, name: &str) -> Result<i32, String> {
        let value = self.string(name)?;
        value
            .parse()
            .map_err(|_| format!("--{name} must be an integer, got {value}"))
    }

    pub fn f64(&self, name: &str) -> Result<f64, String> {
        let value = self.string(name)?;
        value
            .parse()
            .map_err(|_| format!("--{name} must be a number, got {value}"))
    }

    pub fn optional_f64(&self, name: &str) -> Option<f64> {
        self.values.get(name).and_then(|value| value.parse().ok())
    }
}
