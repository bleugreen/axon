import Foundation

public enum AxonEditorURLError: Error, Equatable {
    case unsupportedURL
    case missingPath
}

public enum AxonEditorURL {
    public static let scheme = "axon"
    public static let editHost = "edit"

    public static func url(forEditing fileURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = editHost
        components.queryItems = [
            URLQueryItem(name: "path", value: fileURL.path)
        ]
        return components.url!
    }

    public static func fileURL(from url: URL) throws -> URL {
        guard url.scheme == scheme, url.host == editHost else {
            throw AxonEditorURLError.unsupportedURL
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let path = components?.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty
        else {
            throw AxonEditorURLError.missingPath
        }
        return URL(fileURLWithPath: path)
    }
}
