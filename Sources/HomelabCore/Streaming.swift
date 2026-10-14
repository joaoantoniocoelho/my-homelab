import Foundation

public enum StreamGroup: String, CaseIterable, Sendable { case fast, services, system, vms }

public enum StreamMessage: Equatable, Sendable {
    /// `data` is the raw JSON of the group's payload, decoded by whoever owns that group.
    case sample(StreamGroup, Data)
    case failure(StreamGroup, String)
}

/// Turns raw stdout chunks into messages. Tolerates partial lines, SSH banners and malformed lines.
public struct StreamLineParser {
    private var buffer = Data()
    private static let maxLine = 4_000_000
    public init() {}

    public mutating func feed(_ chunk: Data) -> [StreamMessage] {
        buffer.append(chunk)
        var messages: [StreamMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let message = Self.message(from: Data(line)) { messages.append(message) }
        }
        // A line that never ends is not ours; do not let it grow without bound.
        if buffer.count > Self.maxLine { buffer = Data() }
        return messages
    }

    static func message(from line: Data) -> StreamMessage? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let name = object["group"] as? String, let group = StreamGroup(rawValue: name) else { return nil }
        if let error = object["error"] as? String { return .failure(group, error) }
        guard let payload = object["data"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return .sample(group, data)
    }
}

/// Exponential reconnect delay with jitter, so a rebooting server is not hit with failed logins
/// (OpenSSH `PerSourcePenalties` starts refusing the client's address).
public struct Backoff: Equatable, Sendable {
    public var base = 1.0
    public var cap = 60.0
    public var jitter = 0.2
    public init(base: Double = 1, cap: Double = 60, jitter: Double = 0.2) {
        self.base = base; self.cap = cap; self.jitter = jitter
    }

    /// `random` is in 0..<1; 0.5 means no jitter.
    public func delay(failures: Int, random: Double) -> Double {
        let raw = min(cap, base * pow(2, Double(min(max(failures, 0), 30))))
        return min(cap, max(0, raw * (1 + jitter * (2 * random - 1))))
    }
}

/// One live remote collector. Abstracted so the supervisor can be tested without SSH.
public protocol StreamSession: AnyObject, Sendable {
    var output: AsyncStream<Data> { get }
    func write(_ data: Data)
    func stop()
    /// Why the session ended, in Portuguese; meaningful once `output` has finished.
    var failureDescription: String { get }
}

/// Runs a long-lived process (ssh) and exposes stdout incrementally. Its stdin pipe stays open until `stop()`.
public final class ProcessStreamer: StreamSession, @unchecked Sendable {
    public let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    private let lock = NSLock()
    private var errorData = Data()
    private var stopped = false

    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    public init(executable: String = "/usr/bin/ssh", arguments: [String]) {
        _ = Self.ignoreSIGPIPE
        (output, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
    }

    public func start() throws {
        try process.run()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunk = stderr.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                lock.lock(); if errorData.count < 20_000 { errorData.append(chunk) }; lock.unlock()
            }
            readers.leave()
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                continuation.yield(chunk)
            }
            readers.wait()
            process.waitUntilExit()
            continuation.finish()
        }
    }

    public func write(_ data: Data) {
        lock.lock(); let closed = stopped; lock.unlock()
        guard !closed else { return }
        try? stdin.fileHandleForWriting.write(contentsOf: data)
    }

    public func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    public var failureDescription: String {
        lock.lock(); defer { lock.unlock() }
        let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty { return String(detail.prefix(600)) }
        if process.terminationReason == .uncaughtSignal { return "A conexão foi interrompida ou excedeu o tempo limite." }
        return "O SSH encerrou com código \(process.terminationStatus)."
    }
}

public enum StreamEvent: Equatable, Sendable {
    case connecting
    case message(StreamMessage)
    case disconnected(String)
}

/// Keeps exactly one session alive: reconnects with backoff, and recycles a session whose `fast` samples stopped.
public final class StreamSupervisor: @unchecked Sendable {
    public struct Timing: Sendable {
        public var staleAfter: Double
        public var checkEvery: Double
        public var backoff: Backoff
        public init(staleAfter: Double = 10, checkEvery: Double = 1, backoff: Backoff = Backoff()) {
            self.staleAfter = staleAfter; self.checkEvery = checkEvery; self.backoff = backoff
        }
    }

    /// Only the reconnect delay is injectable; the watchdog always uses real time.
    public typealias Sleep = @Sendable (Double) async throws -> Void
    private let timing: Timing
    private let connect: @Sendable () throws -> any StreamSession
    private let sleep: Sleep
    private let random: @Sendable () -> Double
    private let now: @Sendable () -> Double
    private let onEvent: @Sendable (StreamEvent) -> Void
    private let greeting: @Sendable () -> Data?
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var session: (any StreamSession)?
    private var failures = 0

    public init(timing: Timing = Timing(),
                connect: @escaping @Sendable () throws -> any StreamSession,
                sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                greeting: @escaping @Sendable () -> Data? = { nil },
                onEvent: @escaping @Sendable (StreamEvent) -> Void) {
        self.timing = timing; self.connect = connect; self.sleep = sleep
        self.random = random; self.now = now; self.greeting = greeting; self.onEvent = onEvent
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        failures = 0
        task = Task { [self] in await run() }
    }

    /// Ends the connection and does not reconnect. The remote collector exits on its own once the channel closes.
    public func stop() {
        lock.lock()
        let running = task, current = session
        task = nil; session = nil
        lock.unlock()
        running?.cancel()
        current?.stop()
    }

    /// Lines for the remote collector's stdin (e.g. updated VM probes).
    public func send(_ data: Data) {
        lock.lock(); let current = session; lock.unlock()
        current?.write(data)
    }

    private func nextDelay() -> Double {
        lock.lock(); defer { lock.unlock() }
        defer { failures += 1 }
        return timing.backoff.delay(failures: failures, random: random())
    }
    private func resetFailures() { lock.lock(); failures = 0; lock.unlock() }
    private func adopt(_ current: any StreamSession) { lock.lock(); session = current; lock.unlock() }
    private func release(_ current: any StreamSession) {
        current.stop()
        lock.lock(); if session === current { session = nil }; lock.unlock()
    }

    private func run() async {
        while !Task.isCancelled {
            onEvent(.connecting)
            let reason = await runSession()
            guard !Task.isCancelled else { return }
            onEvent(.disconnected(reason))
            do { try await sleep(nextDelay()) } catch { return }
        }
    }

    private func runSession() async -> String {
        let current: any StreamSession
        do { current = try connect() } catch { return error.localizedDescription }
        adopt(current)
        // Sent on every (re)connection: the remote collector starts with no state.
        if let hello = greeting() { current.write(hello) }
        defer { release(current) }
        let tracker = FastTracker(now())
        let stale = Flag()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                var parser = StreamLineParser()
                for await chunk in current.output {
                    for message in parser.feed(chunk) {
                        if case .sample(let name, _) = message {
                            resetFailures()
                            if name == .fast { tracker.mark(now()) }
                        }
                        onEvent(.message(message))
                    }
                }
            }
            group.addTask { [self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(timing.checkEvery)) } catch { return }
                    if now() - tracker.last > timing.staleAfter {
                        stale.set(); current.stop(); return
                    }
                }
            }
            await group.next()
            group.cancelAll()
        }
        if stale.value { return "Sem dados do servidor há mais de \(String(format: "%g", timing.staleAfter)) s. Reconectando…" }
        return current.failureDescription
    }
}

private final class FastTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ start: Double) { value = start }
    var last: Double { lock.lock(); defer { lock.unlock() }; return value }
    func mark(_ now: Double) { lock.lock(); value = now; lock.unlock() }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
