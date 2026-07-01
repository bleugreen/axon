import Foundation
import Testing
@testable import AxonCore

@Test func editorURLRoundTripsAxnPath() throws {
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

@Test func editorReviewURLRoundTripsAxnPathAndSuggestedName() throws {
    let fileURL = URL(fileURLWithPath: "/tmp/Axon Recordings/demo recording.axn")

    let reviewURL = AxonEditorURL.url(forReviewing: fileURL, suggestedName: "demo recording.axn")

    #expect(reviewURL.scheme == "axon")
    #expect(reviewURL.host == "review")
    #expect(try AxonEditorURL.fileURL(from: reviewURL) == fileURL)
    #expect(AxonEditorURL.suggestedName(from: reviewURL) == "demo recording.axn")
}

@Test func editorInsertURLRoundTripsRecordingTarget() throws {
    let fileURL = URL(fileURLWithPath: "/tmp/Axon Recordings/repair.axn")

    let insertURL = AxonEditorURL.url(
        forInserting: fileURL,
        documentID: "doc-123",
        beforeBlockID: "a002",
        suggestedName: "repair.axn"
    )

    #expect(insertURL.scheme == "axon")
    #expect(insertURL.host == "insert")
    #expect(try AxonEditorURL.fileURL(from: insertURL) == fileURL)
    #expect(AxonEditorURL.documentID(from: insertURL) == "doc-123")
    #expect(AxonEditorURL.beforeBlockID(from: insertURL) == "a002")
    #expect(AxonEditorURL.suggestedName(from: insertURL) == "repair.axn")
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
