fn main() {
    println!("cargo:rerun-if-changed=src/vision_bridge.m");
    println!("cargo:rerun-if-changed=src/vision_bridge.h");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=Vision");
    cc::Build::new()
        .file("src/vision_bridge.m")
        .flag("-fobjc-arc")
        .compile("axon_mac_vision");
}
