#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("axon-mac runs only on macOS");
    std::process::exit(1);
}
#[cfg(target_os = "macos")]
fn main() {
    let result = match std::env::args().nth(1).as_deref().unwrap_or("serve") {
        "serve" => axon_mac::socket::serve(),
        "mcp" => axon_mac::socket::mcp(),
        "probe" => axon_mac::probe::run(&std::env::args().skip(2).collect::<Vec<_>>()),
        "version" | "--version" => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        _ => Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "usage: axon-mac [serve|mcp|probe|version]",
        )),
    };
    if let Err(error) = result {
        eprintln!("axon-mac: {error}");
        std::process::exit(1);
    }
}
