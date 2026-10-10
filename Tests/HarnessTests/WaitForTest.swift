import XCTest

private enum TestWaitError: Error { case timedOut }
func waitForTest(file: StaticString = #filePath, line: UInt = #line,
                 _ condition: () async -> Bool) async throws {
    let started = DispatchTime.now().uptimeNanoseconds
    while !(await condition()) {
        guard DispatchTime.now().uptimeNanoseconds - started < 2_000_000_000 else {
            XCTFail("Synthetic fixture did not become ready within two seconds", file: file, line: line)
            throw TestWaitError.timedOut
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
