use std::env;

#[cfg(target_os = "linux")]
mod linux;

#[derive(Debug)]
struct Options {
    application: Option<String>,
    role: Option<String>,
    name_contains: Option<String>,
    action: bool,
    same_bus: bool,
    expect_text_before: Option<String>,
    expect_text_after: Option<String>,
    max_depth: usize,
    max_nodes: usize,
}

impl Options {
    fn parse(args: impl IntoIterator<Item = String>) -> Result<Self, String> {
        let mut options = Self {
            application: None,
            role: None,
            name_contains: None,
            action: false,
            same_bus: false,
            expect_text_before: None,
            expect_text_after: None,
            max_depth: 8,
            max_nodes: 300,
        };
        let mut args = args.into_iter();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--application" => options.application = Some(value(&mut args, &arg)?),
                "--role" => options.role = Some(value(&mut args, &arg)?),
                "--name-contains" => options.name_contains = Some(value(&mut args, &arg)?),
                "--action" => options.action = true,
                "--same-bus" => options.same_bus = true,
                "--expect-text-before" => {
                    options.expect_text_before = Some(value(&mut args, &arg)?)
                }
                "--expect-text-after" => options.expect_text_after = Some(value(&mut args, &arg)?),
                "--max-depth" => {
                    options.max_depth = value(&mut args, &arg)?
                        .parse()
                        .map_err(|_| "--max-depth must be a non-negative integer".to_owned())?
                }
                "--max-nodes" => {
                    options.max_nodes = value(&mut args, &arg)?
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
        if options.action
            && (options.role.is_none()
                || options.name_contains.is_none()
                || options.expect_text_before.is_none()
                || options.expect_text_after.is_none())
        {
            return Err(
                "--action requires --role, --name-contains, --expect-text-before, and --expect-text-after"
                    .to_owned(),
            );
        }
        Ok(options)
    }
}

fn value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    args.next()
        .ok_or_else(|| format!("{flag} requires a value"))
}

fn usage() -> &'static str {
    "Usage: axon-spike-linux [--application TEXT] [--max-depth N] [--max-nodes N] [--same-bus]\n\
     Locator: --role ROLE --name-contains TEXT [--action\n\
       --expect-text-before TEXT --expect-text-after TEXT]\n\n\
     Without --application, lists application roots on the AT-SPI bus. With an\n\
     application, captures a bounded tree. --same-bus addresses every object reference\n\
     on the existing accessibility bus instead of opening advertised peer sockets.\n\
     --action resolves Click or Activate and\n\
     verifies the expected text transition on the same AT-SPI object reference."
}

#[cfg_attr(not(target_os = "linux"), allow(unused_variables))]
fn main() {
    let options = match Options::parse(env::args().skip(1)) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("{message}");
            std::process::exit(2);
        }
    };

    #[cfg(target_os = "linux")]
    if let Err(error) = linux::run(options) {
        eprintln!("error: {error}");
        std::process::exit(1);
    }

    #[cfg(not(target_os = "linux"))]
    {
        eprintln!("axon-spike-linux requires Linux");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_requires_complete_locator() {
        assert_eq!(
            Options::parse(["--action".to_owned()]).unwrap_err(),
            "--action requires --role, --name-contains, --expect-text-before, and --expect-text-after"
        );
    }

    #[test]
    fn max_nodes_must_be_positive() {
        assert_eq!(
            Options::parse(["--max-nodes".to_owned(), "0".to_owned()]).unwrap_err(),
            "--max-nodes must be a positive integer"
        );
    }
}
