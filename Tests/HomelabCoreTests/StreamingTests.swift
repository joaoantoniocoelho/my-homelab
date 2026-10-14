import XCTest
@testable import HomelabCore

private final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class FakeSession: StreamSession, @unchecked Sendable {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var stoppedFlag = false
    private var written: [Data] = []
    let failureDescription: String
    init(failure: String = "O SSH encerrou com código 255.") {
        (output, continuation) = AsyncStream<Data>.makeStream()
        failureDescription = failure
    }
    func emit(_ text: String) { continuation.yield(Data(text.utf8)) }
    func end() { continuation.finish() }
    func write(_ data: Data) { lock.lock(); written.append(data); lock.unlock() }
    func stop() { lock.lock(); stoppedFlag = true; lock.unlock(); continuation.finish() }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stoppedFlag }
    var writes: [Data] { lock.lock(); defer { lock.unlock() }; return written }
}

private func eventually(timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private let fastLine = #"{"group":"fast","ts":1.5,"data":{"hostname":"h"}}"# + "\n"

final class StreamParserTests: XCTestCase {
    func testLinesSplitAcrossChunksAreReassembled() {
        var parser = StreamLineParser()
        let line = Data(fastLine.utf8)
        XCTAssertTrue(parser.feed(line.prefix(10)).isEmpty)
        let messages = parser.feed(line.dropFirst(10))
        guard case .sample(.fast, let data)? = messages.first else { return XCTFail("expected a fast sample") }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], ["hostname": "h"])
    }

    func testSeveralLinesInOneChunkKeepOrder() {
        var parser = StreamLineParser()
        let text = fastLine + #"{"group":"services","ts":2,"data":{}}"# + "\n" + #"{"group":"system","ts":3,"error":"falhou"}"# + "\n"
        let groups = parser.feed(Data(text.utf8)).map { message -> String in
            switch message {
            case .sample(let group, _): return "sample:" + group.rawValue
            case .failure(let group, let error): return "failure:" + group.rawValue + ":" + error
            }
        }
        XCTAssertEqual(groups, ["sample:fast", "sample:services", "failure:system:falhou"])
    }

    func testBannersGarbageAndUnknownGroupsAreIgnored() {
        var parser = StreamLineParser()
        let text = "Welcome to Ubuntu\n{not json\n" + #"{"group":"nope","ts":1,"data":{}}"# + "\n" + #"{"group":"fast","ts":1}"# + "\n\n" + fastLine
        XCTAssertEqual(parser.feed(Data(text.utf8)).count, 1)
    }

    func testRunawayLineIsDropped() {
        var parser = StreamLineParser()
        _ = parser.feed(Data(repeating: 0x61, count: 4_100_000))
        XCTAssertEqual(parser.feed(Data(fastLine.utf8)).count, 1)
    }
}

final class BackoffTests: XCTestCase {
    func testDoublesFromOneSecondUpToTheCap() {
        let backoff = Backoff()
        let delays = (0..<9).map { backoff.delay(failures: $0, random: 0.5) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 32, 60, 60, 60])
    }

    func testJitterStaysWithinBoundsAndNeverExceedsCap() {
        let backoff = Backoff()
        XCTAssertEqual(backoff.delay(failures: 2, random: 0), 3.2, accuracy: 0.001)
        XCTAssertEqual(backoff.delay(failures: 2, random: 0.999999), 4.8, accuracy: 0.001)
        XCTAssertLessThanOrEqual(backoff.delay(failures: 40, random: 0.999), 60)
    }
}

final class StreamCommandTests: XCTestCase {
    func testStreamArgumentsKeepStdinOpenAndDetectDeadPeers() {
        let args = Connection(host: "alias", user: "me", port: 2222).streamArguments(command: "python3 -u")
        XCTAssertFalse(args.contains("-n"))
        XCTAssertTrue(args.contains("-T"))
        for option in ["BatchMode=yes", "ConnectTimeout=5", "ServerAliveInterval=15", "ServerAliveCountMax=3"] {
            XCTAssertTrue(args.contains(option), option)
        }
        XCTAssertEqual(Array(args.suffix(3)), ["--", "me@alias", "python3 -u"])
        XCTAssertEqual(Array(args.prefix(2)), ["-p", "2222"])
    }

    func testStreamCommandCarriesConfiguredIntervalsAndBothScripts() throws {
        let command = try Telemetry.streamCommand(connection: Connection(interval: 4, servicesInterval: 6, systemInterval: 40))
        XCTAssertTrue(command.hasPrefix("python3 -u -c '"))
        for expected in [" stream 'fast=4.0' 'services=6.0' 'system=40.0' 'vms=15.0' 'vm-uri=qemu:///system' 'vm-script="] {
            XCTAssertTrue(command.contains(expected), expected)
        }
    }

    func testStreamCommandSurvivesTheRemoteShell() async throws {
        // The remote shell re-parses the whole command; the collector must receive its script byte for byte.
        let command = try Telemetry.streamCommand(connection: Connection())
        XCTAssertTrue(command.hasPrefix("python3 "))
        let shell = "set -- " + command.dropFirst("python3 ".count) + #"; printf %s "$#:$3:$4""#
        let result = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", shell])
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: source.appendingPathComponent("Sources/HomelabCore/collector.py"), encoding: .utf8)
        XCTAssertEqual(result.output, "10:" + script + ":stream")
    }
}

final class ProcessStreamerTests: XCTestCase {
    func testStdinStaysOpenAndOutputIsIncremental() async throws {
        let streamer = ProcessStreamer(executable: "/bin/sh", arguments: ["-c", "read line; echo got:$line; read again; echo done:$again"])
        try streamer.start()
        streamer.write(Data("one\n".utf8))
        var received = ""
        for await chunk in streamer.output {
            received += String(decoding: chunk, as: UTF8.self)
            if received.contains("got:one") { break }
        }
        XCTAssertTrue(received.contains("got:one"))
        streamer.write(Data("two\n".utf8))
        for await chunk in streamer.output {
            received += String(decoding: chunk, as: UTF8.self)
            if received.contains("done:two") { break }
        }
        XCTAssertTrue(received.contains("done:two"))
        streamer.stop()
    }

    func testStopEndsALongRunningProcess() async throws {
        let streamer = ProcessStreamer(executable: "/bin/sleep", arguments: ["30"])
        try streamer.start()
        let began = Date()
        streamer.stop()
        for await _ in streamer.output { }
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    func testClosingStdinLetsTheRemoteSideSeeEOF() async throws {
        let streamer = ProcessStreamer(executable: "/bin/sh", arguments: ["-c", "cat >/dev/null; echo eof"])
        try streamer.start()
        let reader = Task { () -> String in
            var text = ""
            for await chunk in streamer.output { text += String(decoding: chunk, as: UTF8.self) }
            return text
        }
        streamer.stop()
        _ = await reader.value
    }

    func testFailureDescriptionPrefersStderr() async throws {
        let streamer = ProcessStreamer(executable: "/bin/sh", arguments: ["-c", "echo 'Permission denied' >&2; exit 255"])
        try streamer.start()
        for await _ in streamer.output { }
        XCTAssertEqual(streamer.failureDescription, "Permission denied")
    }

    func testFailureDescriptionFallsBackToExitCode() async throws {
        let streamer = ProcessStreamer(executable: "/bin/sh", arguments: ["-c", "exit 7"])
        try streamer.start()
        for await _ in streamer.output { }
        XCTAssertEqual(streamer.failureDescription, "O SSH encerrou com código 7.")
    }
}

final class StreamEndToEndTests: XCTestCase {
    /// The real collector and parser through a local shell: no SSH, so no orphan can hide behind a remote sshd.
    func testRealCollectorStreamsAllGroupsAndDiesWithItsStdin() async throws {
        let command = try Telemetry.streamCommand(connection: Connection(interval: 2, servicesInterval: 5, systemInterval: 30))
        let streamer = ProcessStreamer(executable: "/bin/sh", arguments: ["-c", command])
        try streamer.start()
        streamer.write(Data(#"{"probes":{}}"#.utf8) + Data("\n".utf8))
        var parser = StreamLineParser()
        var groups = Set<StreamGroup>()
        let deadline = Date().addingTimeInterval(15)
        for await chunk in streamer.output {
            for message in parser.feed(chunk) {
                switch message {
                case .sample(let group, _), .failure(let group, _): groups.insert(group)
                }
            }
            if groups == Set(StreamGroup.allCases) || Date() > deadline { break }
        }
        XCTAssertEqual(groups, Set(StreamGroup.allCases))
        streamer.stop()
        for await _ in streamer.output { }
        // stdin EOF is the only thing that can end the Python child once its shell parent is gone.
        let gone = await eventually(timeout: 5) {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", "dependency-free Linux collector"]
            pgrep.standardOutput = FileHandle.nullDevice
            try? pgrep.run(); pgrep.waitUntilExit()
            return pgrep.terminationStatus == 1
        }
        XCTAssertTrue(gone, "collector outlived its connection")
    }
}

final class StreamSupervisorTests: XCTestCase {
    func testReconnectsWithExponentialBackoffAndStopsWhenCancelled() async {
        let delays = Recorder<Double>()
        let connects = Recorder<Int>()
        let supervisor = StreamSupervisor(
            connect: { connects.add(1); let session = FakeSession(); session.end(); return session },
            sleep: { delay in
                delays.add(delay)
                if delays.all.count >= 5 { throw CancellationError() }
            },
            random: { 0.5 }, onEvent: { _ in })
        supervisor.start()
        _ = await eventually { delays.all.count >= 5 }
        XCTAssertEqual(delays.all, [1, 2, 4, 8, 16])
        XCTAssertEqual(connects.all.count, 5)
        supervisor.stop()
    }

    func testValidSampleResetsTheBackoff() async {
        let delays = Recorder<Double>()
        let attempt = Recorder<Int>()
        let supervisor = StreamSupervisor(
            connect: {
                attempt.add(1)
                let session = FakeSession()
                // Attempts 1-2 fail at once; attempt 3 delivers a sample before dying; attempt 4 fails again.
                if attempt.all.count == 3 { session.emit(fastLine) }
                session.end()
                return session
            },
            sleep: { delay in
                delays.add(delay)
                if delays.all.count >= 4 { throw CancellationError() }
            },
            random: { 0.5 }, onEvent: { _ in })
        supervisor.start()
        _ = await eventually { delays.all.count >= 4 }
        XCTAssertEqual(delays.all, [1, 2, 1, 2])
        supervisor.stop()
    }

    func testWatchdogRecyclesASessionThatStopsSendingFastSamples() async {
        let sessions = Recorder<FakeSession>()
        let events = Recorder<StreamEvent>()
        let supervisor = StreamSupervisor(
            timing: .init(staleAfter: 0.3, checkEvery: 0.05, backoff: Backoff(base: 0.05, cap: 0.05, jitter: 0)),
            connect: { let session = FakeSession(); sessions.add(session); return session },
            onEvent: { events.add($0) })
        supervisor.start()
        let recycled = await eventually { sessions.all.count >= 2 }
        XCTAssertTrue(recycled)
        XCTAssertTrue(sessions.all[0].stopped)
        XCTAssertTrue(events.all.contains(.disconnected("Sem dados do servidor há mais de 0.3 s. Reconectando…")))
        supervisor.stop()
        XCTAssertTrue(sessions.all.last!.stopped)
    }

    func testSamplesOfOtherGroupsDoNotFeedTheWatchdog() async {
        let sessions = Recorder<FakeSession>()
        let supervisor = StreamSupervisor(
            timing: .init(staleAfter: 0.3, checkEvery: 0.05, backoff: Backoff(base: 5, cap: 5, jitter: 0)),
            connect: { let session = FakeSession(); sessions.add(session); return session },
            onEvent: { _ in })
        supervisor.start()
        _ = await eventually { !sessions.all.isEmpty }
        let session = sessions.all[0]
        for _ in 0..<5 {
            session.emit(#"{"group":"services","ts":1,"data":{}}"# + "\n")
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(session.stopped, "only fast samples keep a session alive")
        supervisor.stop()
    }

    func testFastSamplesKeepTheSessionAliveAndAreForwarded() async {
        let sessions = Recorder<FakeSession>()
        let events = Recorder<StreamEvent>()
        let supervisor = StreamSupervisor(
            timing: .init(staleAfter: 0.3, checkEvery: 0.05),
            connect: { let session = FakeSession(); sessions.add(session); return session },
            onEvent: { events.add($0) })
        supervisor.start()
        _ = await eventually { !sessions.all.isEmpty }
        let session = sessions.all[0]
        for _ in 0..<8 {
            session.emit(fastLine)
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(session.stopped)
        XCTAssertEqual(sessions.all.count, 1)
        XCTAssertGreaterThanOrEqual(events.all.filter { if case .message(.sample(.fast, _)) = $0 { return true } else { return false } }.count, 8)
        supervisor.stop()
    }

    func testDisconnectReportsTheSessionFailureAndConnectErrors() async {
        let events = Recorder<StreamEvent>()
        let attempt = Recorder<Int>()
        let supervisor = StreamSupervisor(
            connect: {
                attempt.add(1)
                if attempt.all.count == 1 { throw TelemetryError.invalid("sem ssh") }
                let session = FakeSession(failure: "Permission denied")
                session.end()
                return session
            },
            sleep: { _ in if attempt.all.count >= 2 { throw CancellationError() } },
            onEvent: { events.add($0) })
        supervisor.start()
        _ = await eventually { events.all.contains(.disconnected("Permission denied")) }
        XCTAssertEqual(events.all.first, .connecting)
        XCTAssertTrue(events.all.contains(.disconnected("sem ssh")))
        XCTAssertTrue(events.all.contains(.disconnected("Permission denied")))
        supervisor.stop()
    }

    func testStopClosesTheSessionAndDoesNotReconnect() async {
        let sessions = Recorder<FakeSession>()
        let supervisor = StreamSupervisor(
            connect: { let session = FakeSession(); sessions.add(session); return session },
            onEvent: { _ in })
        supervisor.start()
        _ = await eventually { !sessions.all.isEmpty }
        supervisor.stop()
        let closed = await eventually { sessions.all[0].stopped }
        XCTAssertTrue(closed)
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(sessions.all.count, 1)
    }

    func testSendWritesToTheLiveSession() async {
        let sessions = Recorder<FakeSession>()
        let supervisor = StreamSupervisor(
            connect: { let session = FakeSession(); sessions.add(session); return session },
            onEvent: { _ in })
        supervisor.start()
        _ = await eventually { !sessions.all.isEmpty }
        supervisor.send(Data("probes\n".utf8))
        XCTAssertEqual(sessions.all[0].writes, [Data("probes\n".utf8)])
        supervisor.stop()
    }
}
