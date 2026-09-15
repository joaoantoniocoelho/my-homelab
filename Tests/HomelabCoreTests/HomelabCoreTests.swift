import XCTest
@testable import HomelabCore

final class HomelabCoreTests: XCTestCase {
    private let payload = #"{"hostname":"homelab","uptime":null,"cpu":12.5,"cores":12,"load":[0.1,0.2,0.3],"memoryUsed":1000,"memoryTotal":2000,"diskUsed":null,"diskTotal":null,"gpus":[{"index":0,"name":"RTX 3060","uuid":"GPU-1","driver":"595","temperature":40,"utilization":0,"memoryUsed":1024,"memoryTotal":12288,"power":19.8,"powerLimit":170,"fan":null,"gpuClock":210,"memoryClock":405}],"processes":[{"gpuUUID":"GPU-1","pid":42,"name":"/usr/bin/ollama","memory":1024}],"models":[],"services":[],"warnings":[],"nvtopAvailable":true}"#

    func testTelemetryFramingAndUnits() throws {
        let date = Date(timeIntervalSince1970: 100)
        let snapshot = try Telemetry.parse("Welcome banner\n__HL_JSON_BEGIN__\n" + payload + "\n__HL_JSON_END__\n", at: date)
        XCTAssertEqual(snapshot.timestamp, date)
        XCTAssertEqual(snapshot.cpu, 12.5)
        XCTAssertEqual(snapshot.gpus[0].memoryPercent!, 100.0 / 12, accuracy: 0.001)
        XCTAssertNil(snapshot.gpus[0].fan)
        XCTAssertEqual(snapshot.gpus[0].utilization, 0)
        XCTAssertEqual(snapshot.processes[0].id, "GPU-1-42")
    }
    func testTruncatedOrUnframedDataRejected() {
        XCTAssertThrowsError(try Telemetry.parse(payload))
        XCTAssertThrowsError(try Telemetry.parse("__HL_JSON_BEGIN__\n" + payload))
        XCTAssertThrowsError(try Telemetry.parse("__HL_JSON_BEGIN__\n{}\n__HL_JSON_END__"))
    }
    func testInvalidCPURejected() {
        XCTAssertThrowsError(try Telemetry.parse("__HL_JSON_BEGIN__\n" + payload.replacingOccurrences(of: "12.5", with: "150") + "\n__HL_JSON_END__"))
    }
    func testConnectionValidationAndCadences() {
        XCTAssertTrue(Connection().isValid)
        XCTAssertEqual(Connection().destination, "homelab")
        XCTAssertEqual(Connection().user, "")
        XCTAssertTrue(Connection(host: "my-ssh-alias", user: "").isValid)
        XCTAssertFalse(Connection(host: "-oProxyCommand=bad").isValid)
        XCTAssertFalse(Connection(host: "host; touch /tmp/unsafe").isValid)
        XCTAssertFalse(Connection(user: "user\nother").isValid)
        XCTAssertFalse(Connection(port: 65536).isValid)
        XCTAssertFalse(Connection(interval: 1).isValid)
        XCTAssertFalse(Connection(servicesInterval: 11).isValid)
        XCTAssertFalse(Connection(systemInterval: 29).isValid)
    }
    func testSSHPreservesTrustAndBatchMode() {
        let config = Connection(host: "alias", user: "")
        let args = config.arguments(interactive: false, command: "uptime")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertEqual(Array(args.suffix(3)), ["--", "alias", "uptime"])
        XCTAssertFalse(args.contains { $0.contains("StrictHostKeyChecking=no") })
        XCTAssertTrue(config.arguments(interactive: true).contains("-tt"))
        XCTAssertFalse(config.arguments(interactive: true).contains("BatchMode=yes"))
    }
    func testShellQuotingRoundTrip() async throws {
        let input = "single' quote\n$(echo unsafe) `uname` ; end"
        let result = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "printf %s " + Connection.shellQuote(input)])
        XCTAssertEqual(result.output, input)
    }
    func testCommandOutputAndFailure() async throws {
        let result = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 7"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(result.output, "out")
        XCTAssertEqual(result.error, "err")
    }
    func testTimeoutAndCancellation() async throws {
        let start = Date()
        let result = try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let task = Task { try await ProcessRunner.run(executable: "/bin/sleep", arguments: ["10"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCollectorResourceAndGroups() throws {
        for group in CollectionGroup.allCases {
            let command = try Telemetry.command(group: group)
            XCTAssertTrue(command.hasPrefix("python3 -c '"))
            XCTAssertTrue(command.hasSuffix(" " + group.rawValue))
        }
    }
}
