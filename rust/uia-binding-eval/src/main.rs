//! Experimental direct Windows UI Automation binding evaluation.

#[cfg(windows)]
mod windows_eval;

#[cfg(windows)]
fn main() {
    if let Err(error) = windows_eval::run(std::env::args().skip(1).collect()) {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("uia-binding-eval requires Windows");
    std::process::exit(1);
}
