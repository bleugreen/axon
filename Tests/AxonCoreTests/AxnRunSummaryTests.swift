import Testing
@testable import AxonCore

@Test func axnRunSummaryReportsBatchFailureWithActionAndFact() {
    let stdout = """
    {"jsonrpc":"2.0","id":"run_batch","result":{"batch":{"success":false,"trace":[{"index":0,"tool":"set_value","success":true},{"index":1,"success":false,"actionId":"a002","factId":"a001.value.0","error":"Fact a001.value.0 did not verify"}]}}}
    """

    let summary = AxnRunSummary.failureMessage(
        fileName: "recording.axn",
        terminationStatus: 0,
        stdout: stdout,
        stderr: ""
    )

    #expect(summary?.contains("recording.axn did not complete") == true)
    #expect(summary?.contains("Action: a002") == true)
    #expect(summary?.contains("Fact: a001.value.0") == true)
    #expect(summary?.contains("Fact a001.value.0 did not verify") == true)
}

@Test func axnRunSummaryReportsTransportErrors() {
    let summary = AxnRunSummary.failureMessage(
        fileName: "recording.axn",
        terminationStatus: 1,
        stdout: "",
        stderr: "axon: connection refused"
    )

    #expect(summary?.contains("exited with status 1") == true)
    #expect(summary?.contains("connection refused") == true)
}

@Test func axnRunSummaryReportsJSONRPCErrors() {
    let stdout = """
    {"jsonrpc":"2.0","id":"run_batch","error":{"code":-32602,"message":"Locator did not resolve uniquely: missing"}}
    """

    let summary = AxnRunSummary.failureMessage(
        fileName: "recording.axn",
        terminationStatus: 0,
        stdout: stdout,
        stderr: ""
    )

    #expect(summary?.contains("recording.axn failed") == true)
    #expect(summary?.contains("Locator did not resolve uniquely: missing") == true)
}

@Test func axnRunSummaryReturnsNilForSuccessfulBatch() {
    let stdout = """
    {"jsonrpc":"2.0","id":"run_batch","result":{"batch":{"success":true,"trace":[]}}}
    """

    let summary = AxnRunSummary.failureMessage(
        fileName: "recording.axn",
        terminationStatus: 0,
        stdout: stdout,
        stderr: ""
    )

    #expect(summary == nil)
}
