# System Swift Toolchain Mismatch

## Summary

The system Command Line Tools SwiftPM installation was unable to build Swift packages. Axon now uses Swiftly-managed Swift 6.3.1 for project builds.

## Original Evidence

Before repair, `swift --version` reported:

```text
swift-driver version: 1.127.14.1 Apple Swift version 6.2.1 (swiftlang-6.2.1.4.8 clang-1700.4.4.1)
Target: arm64-apple-macosx26.0
```

`swift test` failed even for a freshly generated package with:

```text
Undefined symbols for architecture arm64:
  "PackageDescription.Package.__allocating_init(...)
```

Manual `swiftc` compilation failed with:

```text
this SDK is not supported by the compiler
the SDK is built with 'Apple Swift version 6.2.1 ... swiftlang-6.2.1.4.7'
while this compiler is 'Apple Swift version 6.2.1 ... swiftlang-6.2.1.4.8'
```

After updating Command Line Tools to 26.5, system `swift --version` reported Swift 6.3.2, but system `swift test` still failed with a `PackageDescription` link error.

## Project Resolution

Installed Swiftly into the user account and initialized Axon with Swift 6.3.1:

```sh
installer -pkg /tmp/swiftly.pkg -target CurrentUserHomeDirectory
~/.swiftly/bin/swiftly init
```

Swiftly created `.swift-version`:

```text
6.3.1
```

Use the Swiftly binary for project commands:

```sh
~/.swiftly/bin/swift test
~/.swiftly/bin/swift build
```

## Remaining System Issue

The Apple Command Line Tools SwiftPM install still appears internally inconsistent. That is outside Axon's project setup now, but it may affect other Swift projects that use `/Library/Developer/CommandLineTools/usr/bin/swift`.
