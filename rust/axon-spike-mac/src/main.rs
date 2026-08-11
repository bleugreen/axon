use std::env;

#[cfg(target_os = "macos")]
mod macos;

#[derive(Debug)]
struct Options {
    pid: i32,
    role: Option<String>,
    name_contains: Option<String>,
    action: bool,
    expect_before: Option<String>,
    expect_after: Option<String>,
    max_depth: usize,
    max_nodes: usize,
}

impl Options {
    fn parse(args: impl IntoIterator<Item = String>) -> Result<Self, String> {
        let mut pid = None;
        let mut options = Self {
            pid: 0,
            role: None,
            name_contains: None,
            action: false,
            expect_before: None,
            expect_after: None,
            max_depth: 12,
            max_nodes: 500,
        };
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--pid" => pid = Some(value(&mut args, &arg)?.parse().map_err(|_| "--pid must be an integer")?),
                "--role" => options.role = Some(value(&mut args, &arg)?),
                "--name-contains" => options.name_contains = Some(value(&mut args, &arg)?),
                "--action" => options.action = true,
                "--expect-before" => options.expect_before = Some(value(&mut args, &arg)?),
                "--expect-after" => options.expect_after = Some(value(&mut args, &arg)?),
                "--max-depth" => options.max_depth = value(&mut args, &arg)?.parse().map_err(|_| "--max-depth must be an integer")?,
                "--max-nodes" => options.max_nodes = value(&mut args, &arg)?.parse().map_err(|_| "--max-nodes must be an integer")?,
                "--help" | "-h" => return Err(usage().to_owned()),
                other => return Err(format!("unknown argument: {other}\n\n{}", usage())),
            }
        }
        options.pid = pid.ok_or_else(|| "--pid is required".to_owned())?;
        if options.max_nodes == 0 { return Err("--max-nodes must be positive".to_owned()); }
        if options.action && (options.role.is_none() || options.name_contains.is_none() || options.expect_before.is_none() || options.expect_after.is_none()) {
            return Err("--action requires --role, --name-contains, --expect-before, and --expect-after".to_owned());
        }
        Ok(options)
    }
}

fn value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    args.next().ok_or_else(|| format!("{flag} requires a value"))
}

fn usage() -> &'static str {
    "Usage: axon-spike-mac --pid PID [--max-depth N] [--max-nodes N]\n\
     Action: --role ROLE --name-contains TEXT --action\n\
       --expect-before TEXT --expect-after TEXT\n\n\
     Walks a process with direct ApplicationServices AX C API bindings. The action\n\
     performs AXPress and verifies the expected value exists before and after."
}

fn main() {
    let options = match Options::parse(env::args().skip(1)) {
        Ok(options) => options,
        Err(error) => { eprintln!("{error}"); std::process::exit(2); }
    };
    #[cfg(target_os = "macos")]
    if let Err(error) = macos::run(&options) { eprintln!("error: {error}"); std::process::exit(1); }
    #[cfg(not(target_os = "macos"))]
    { let _ = options; eprintln!("axon-spike-mac requires macOS"); std::process::exit(1); }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn action_requires_verification_contract() {
        let error = Options::parse(["--pid".into(), "1".into(), "--action".into()]).unwrap_err();
        assert!(error.starts_with("--action requires"));
    }
}