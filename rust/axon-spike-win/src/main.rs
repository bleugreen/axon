use std::env;

#[cfg(windows)]
mod windows;

#[cfg(any(windows, test))]
#[derive(Clone, Debug, Eq, PartialEq)]
struct Node {
    depth: usize,
    control_type: String,
    name: String,
    automation_id: String,
    rect: String,
}

#[derive(Debug)]
struct Options {
    window_name: Option<String>,
    control_type: Option<String>,
    name_contains: Option<String>,
    invoke: bool,
    activate_msaa: bool,
    max_depth: usize,
    max_nodes: usize,
}

impl Options {
    fn parse(args: impl IntoIterator<Item = String>) -> Result<Self, String> {
        let mut options = Self {
            window_name: None,
            control_type: None,
            name_contains: None,
            invoke: false,
            activate_msaa: false,
            max_depth: 6,
            max_nodes: 250,
        };
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--window" => options.window_name = Some(value(&mut args, "--window")?),
                "--type" => options.control_type = Some(value(&mut args, "--type")?),
                "--name-contains" => {
                    options.name_contains = Some(value(&mut args, "--name-contains")?)
                }
                "--invoke" => options.invoke = true,
                "--activate-msaa" => options.activate_msaa = true,
                "--max-depth" => {
                    options.max_depth = value(&mut args, "--max-depth")?
                        .parse()
                        .map_err(|_| "--max-depth must be a non-negative integer".to_owned())?
                }
                "--max-nodes" => {
                    options.max_nodes = value(&mut args, "--max-nodes")?
                        .parse()
                        .map_err(|_| "--max-nodes must be a positive integer".to_owned())?;
                    if options.max_nodes == 0 {
                        return Err("--max-nodes must be a positive integer".to_owned());
                    }
                }
                "--help" | "-h" => return Err(usage().to_owned()),
                other => return Err(format!("unknown argument: {other}\n\n{}", usage())),
            }
        }
        if options.invoke && (options.control_type.is_none() || options.name_contains.is_none()) {
            return Err("--invoke requires both --type and --name-contains".to_owned());
        }
        Ok(options)
    }
}

fn value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    args.next()
        .ok_or_else(|| format!("{flag} requires a value"))
}

#[cfg(any(windows, test))]
fn matches_locator(node: &Node, control_type: &str, name_contains: &str) -> bool {
    node.control_type.eq_ignore_ascii_case(control_type)
        && node
            .name
            .to_lowercase()
            .contains(&name_contains.to_lowercase())
}

fn usage() -> &'static str {
    "Usage: axon-spike-win [--window TEXT] [--max-depth N] [--max-nodes N] [--activate-msaa]\n\
     Locator: --type TYPE --name-contains TEXT [--invoke]\n\n\
     Without --window, prints top-level UIA windows. With --window, captures the first\n\
     matching window. --invoke dispatches InvokePattern and independently verifies a\n\
     change in the recaptured bounded tree. --activate-msaa sends an OBJID_CLIENT\n\
     MSAA query to the selected window and all of its child HWNDs before capture."
}

fn main() {
    let options = match Options::parse(env::args().skip(1)) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    };

    #[cfg(windows)]
    if let Err(error) = windows::run(&options) {
        eprintln!("error: {error}");
        std::process::exit(1);
    }

    #[cfg(not(windows))]
    {
        let _ = options;
        eprintln!("axon-spike-win requires Windows");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locator_is_case_insensitive_and_requires_both_fields() {
        let node = Node {
            depth: 2,
            control_type: "Button".to_owned(),
            name: "Save As".to_owned(),
            automation_id: "FileSaveAs".to_owned(),
            rect: "(1,2 3x4)".to_owned(),
        };
        assert!(matches_locator(&node, "button", "save"));
        assert!(!matches_locator(&node, "MenuItem", "save"));
        assert!(!matches_locator(&node, "Button", "close"));
    }

    #[test]
    fn invoke_requires_a_complete_locator() {
        let result = Options::parse(["--invoke".to_owned()]);
        assert_eq!(
            result.unwrap_err(),
            "--invoke requires both --type and --name-contains"
        );
    }

    #[test]
    fn parses_msaa_activation() {
        let options = Options::parse(["--activate-msaa".to_owned()]).unwrap();
        assert!(options.activate_msaa);
    }
}
