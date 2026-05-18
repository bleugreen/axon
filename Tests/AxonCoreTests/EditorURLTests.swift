import Foundation
import Testing
@testable import AxonCore

@Test func editorURLRoundTripsRecipePath() throws {
    let fileURL = URL(fileURLWithPath: "/Users/mitch/Documents/Axon Recordings/hello world.axn")

    let editURL = AxonEditorURL.url(forEditing: fileURL)

    #expect(editURL.scheme == "axon")
    #expect(editURL.host == "edit")
    #expect(try AxonEditorURL.fileURL(from: editURL) == fileURL)
}

@Test func editorURLRejectsNonEditURL() {
    let url = URL(string: "axon://run?path=/tmp/example.axn")!

    do {
        _ = try AxonEditorURL.fileURL(from: url)
        Issue.record("non-edit URL should be rejected")
    } catch AxonEditorURLError.unsupportedURL {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func editorURLRejectsMissingPath() {
    let url = URL(string: "axon://edit")!

    do {
        _ = try AxonEditorURL.fileURL(from: url)
        Issue.record("edit URL without path should be rejected")
    } catch AxonEditorURLError.missingPath {
        // Expected.
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
