import Foundation

/// The command line's error vocabulary, shared by the argument parser and the CLI entry point.
///
/// It lives in the library rather than in `AxonCLI` so that `CLICommandParser` can throw it and
/// tests can name it. The exit-code contract below is the part consumers script against.
public enum CLIError: Error, CustomStringConvertible {
    case missingArguments(String)
    case invalidArguments(String)
    case operationFailed(String)

    public var description: String {
        switch self {
        case let .missingArguments(message):
            return message
        case let .invalidArguments(message):
            return message
        case let .operationFailed(message):
            return message
        }
    }

    /// The shared exit-code contract: 2 means the command was used wrongly, 1 means it was used
    /// correctly and could not be completed. Anything a consumer scripts against depends on the
    /// difference, so it is stated once here rather than at each throw site.
    public var exitCode: Int32 {
        switch self {
        case .missingArguments:
            return 2
        case .invalidArguments, .operationFailed:
            return 1
        }
    }
}
