import Foundation

public enum AxonEditorURLError: Error, Equatable {
    case unsupportedURL
    case missingPath
}

public enum AxonEditorURL {
    public static let scheme = "axon"
    public static let editHost = "edit"
    public static let reviewHost = "review"
    public static let insertHost = "insert"

    public static func url(forEditing fileURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = editHost
        components.queryItems = [
            URLQueryItem(name: "path", value: fileURL.path)
        ]
        return components.url!
    }

    public static func url(forReviewing fileURL: URL, suggestedName: String? = nil) -> URL {
        reviewURL(host: reviewHost, fileURL: fileURL, suggestedName: suggestedName)
    }

    public static func url(
        forInserting fileURL: URL,
        documentID: String,
        beforeBlockID: String?,
        suggestedName: String? = nil
    ) -> URL {
        var queryItems = [
            URLQueryItem(name: "path", value: fileURL.path),
            URLQueryItem(name: "documentId", value: documentID)
        ]
        if let beforeBlockID, !beforeBlockID.isEmpty {
            queryItems.append(URLQueryItem(name: "beforeBlockId", value: beforeBlockID))
        }
        if let suggestedName, !suggestedName.isEmpty {
            queryItems.append(URLQueryItem(name: "name", value: suggestedName))
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = insertHost
        components.queryItems = queryItems
        return components.url!
    }

    private static func reviewURL(host: String, fileURL: URL, suggestedName: String?) -> URL {
        var queryItems = [
            URLQueryItem(name: "path", value: fileURL.path)
        ]
        if let suggestedName, !suggestedName.isEmpty {
            queryItems.append(URLQueryItem(name: "name", value: suggestedName))
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = queryItems
        return components.url!
    }

    public static func fileURL(from url: URL) throws -> URL {
        guard url.scheme == scheme, [editHost, reviewHost, insertHost].contains(url.host) else {
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

    public static func suggestedName(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == reviewHost || url.host == insertHost else {
            return nil
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "name" })?
            .value
    }

    public static func documentID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == insertHost else {
            return nil
        }
        return queryValue("documentId", from: url)
    }

    public static func beforeBlockID(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == insertHost else {
            return nil
        }
        return queryValue("beforeBlockId", from: url)
    }

    private static func queryValue(_ name: String, from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
