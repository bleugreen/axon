import Foundation

public enum AxnRunSummary {
    public static func failureMessage(
        fileName: String,
        terminationStatus: Int32,
        stdout: String,
        stderr: String
    ) -> String? {
        if let batchFailure = batchFailureMessage(fileName: fileName, stdout: stdout) {
            return batchFailure
        }

        guard terminationStatus != 0 else {
            return nil
        }

        let detail = firstNonEmpty(stderr, stdout) ?? "No diagnostic output was produced."
        return "\(fileName) exited with status \(terminationStatus).\n\n\(detail)"
    }

    private static func batchFailureMessage(fileName: String, stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let response = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return nil
        }

        if let error = response["error"]?["message"]?.displayString {
            return "\(fileName) failed.\n\n\(error)"
        }

        guard response["result"]?["batch"]?["success"] == .bool(false) else {
            return nil
        }

        let failed = response["result"]?["batch"]?["trace"]?.arrayValue?.first { record in
            record["success"] == .bool(false)
        }
        var lines = ["\(fileName) did not complete."]
        if let index = failed?["index"]?.displayString {
            lines.append("Step: \(index)")
        }
        if let actionID = failed?["actionId"]?.displayString {
            lines.append("Action: \(actionID)")
        }
        if let factID = failed?["factId"]?.displayString {
            lines.append("Fact: \(factID)")
        }
        if let tool = failed?["tool"]?.displayString {
            lines.append("Tool: \(tool)")
        }
        if let error = failed?["error"]?.displayString {
            lines.append("")
            lines.append(error)
        }
        return lines.joined(separator: "\n")
    }

    private static func firstNonEmpty(_ values: String...) -> String? {
        values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private extension JSONValue {
    var arrayValue: [JSONValue]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values
    }

    var displayString: String? {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return String(value)
        case let .double(value):
            return String(value)
        case let .bool(value):
            return String(value)
        case .null, .object, .array:
            return nil
        }
    }
}
