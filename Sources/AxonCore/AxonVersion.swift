/// The product version, shared by the MCP `serverInfo`, health documents, and packaged bundles.
///
/// The checked-in `VERSION` file at the repository root is the release source; this literal is a
/// derived copy because Swift needs it at compile time. `scripts/check-version` fails the build
/// when the two disagree, and `scripts/check-version --write` resynchronizes them.
public enum AxonVersion {
    public static let current = "0.2.1"
}
