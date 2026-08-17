//! The native half of the macOS PID-targeted input acceptance campaign.
//!
//! `scripts/macos-toolkit-acceptance/harness.py` drives this binary. Every
//! subcommand answers with one JSON object on stdout and exits zero, or prints
//! `{"error": "..."}` and exits one. The coordinator owns the phases and the
//! verdicts; this owns everything that can only be done through a native API.
//!
//! Compiled for macOS only. On any other platform it refuses before a single
//! Core Graphics binding is reached, so a Linux `cargo check` of this crate
//! fails with a sentence rather than a screen of missing symbols.

#[cfg(target_os = "macos")]
mod args;
#[cfg(target_os = "macos")]
mod commands;
#[cfg(target_os = "macos")]
mod fixture;
#[cfg(target_os = "macos")]
mod json;
#[cfg(target_os = "macos")]
mod sys;

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!(
        "acceptance-probe measures macOS PID-targeted input delivery and runs on macOS only.\n\
         There is nothing here to run on this platform, and nothing here is product code: see\n\
         scripts/macos-toolkit-acceptance/README.md."
    );
    std::process::exit(64);
}

#[cfg(target_os = "macos")]
fn main() {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = raw.first().cloned() else {
        eprintln!("{}", USAGE);
        std::process::exit(2);
    };
    if command == "--help" || command == "-h" || command == "help" {
        println!("{USAGE}");
        return;
    }
    let parsed = args::Args::parse(&raw[1..]);
    if command == "fixture" {
        if let Err(problem) = fixture::run(&parsed) {
            fail(&problem);
        }
        return;
    }
    match commands::run(&command, &parsed) {
        Ok(value) => println!("{}", value.render()),
        Err(problem) => fail(&problem),
    }
}

#[cfg(target_os = "macos")]
fn fail(problem: &str) -> ! {
    println!("{}", json::J::obj(vec![("error", json::J::str(problem))]).render());
    std::process::exit(1);
}

#[cfg(target_os = "macos")]
const USAGE: &str = "\
acceptance-probe <command> [--key value]

  env                              machine facts and whether this process is Accessibility-trusted
  frontmost                        the frontmost application
  pointer                          the real cursor position
  park --x --y                     move the real cursor somewhere provably clear of the targets
  app --pid                        one running application's dispatch-time identity
  find-app --bundle-id             every running application with this bundle identifier
  windows [--pid]                  the on-screen window stack, front to back
  owner-at --x --y                 the window stack at one point: the ownership proof before dispatch
  post-click --pid --x --y [--source null|hid|combined|private]
  post-key --pid --text [--source ...]
  foreground-click --x --y [--pid] [--restore]      the control
  foreground-key --pid --text [--restore]           the control
  activate --pid
  ax-read --pid                    Accessibility readback of the focused window's document and title
  fixture --nonce [--role target|decoy] [--title] [--report URL] [--x --y --width --height]
";
