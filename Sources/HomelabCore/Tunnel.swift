import Darwin
import Foundation

public struct TunnelSpec: Hashable, Sendable {
    public let localPort: Int
    public let remoteHost: String
    public let remotePort: Int

    public init(localPort: Int, remoteHost: String, remotePort: Int) {
        self.localPort = localPort; self.remoteHost = remoteHost; self.remotePort = remotePort
    }

    /// Always bound to IPv4 loopback: RDP is never reachable from the LAN.
    public var forward: String {
        let host = remoteHost.contains(":") ? "[\(remoteHost)]" : remoteHost
        return "127.0.0.1:\(localPort):\(host):\(remotePort)"
    }

    public func arguments(via connection: Connection) -> [String] {
        // No multiplexing: a shared master would own the forward and break our process supervision.
        ["-N", "-T", "-p", String(connection.port),
         "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
         "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
         "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "GatewayPorts=no",
         "-L", forward, "--", connection.destination]
    }
}

public protocol TunnelProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    var errorOutput: String { get }
    func terminate()
}

/// Owns one `ssh -N -L` child. stderr is kept (bounded) to explain failures.
public final class SSHTunnelProcess: TunnelProcess, @unchecked Sendable {
    private let process = Process()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var captured = Data()

    public init(executable: String = "/usr/bin/ssh", arguments: [String], onExit: @escaping @Sendable () -> Void) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            self.lock.lock(); if self.captured.count < 8_192 { self.captured.append(chunk.prefix(8_192 - self.captured.count)) }; self.lock.unlock()
        }
        process.terminationHandler = { _ in onExit() }
        try process.run()
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }
    public var errorOutput: String { lock.lock(); defer { lock.unlock() }; return String(decoding: captured, as: UTF8.self) }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

public enum NetworkProbe {
    /// TPKT + X.224 Connection Request + RDP negotiation request (TLS | CredSSP).
    public static let rdpRequest: [UInt8] = [0x03, 0x00, 0x00, 0x13, 0x0e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,
                                             0x01, 0x00, 0x08, 0x00, 0x03, 0x00, 0x00, 0x00]

    /// TPKT version 3 carrying an X.224 Connection Confirm.
    public static func isRDPResponse(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 6 && bytes[0] == 0x03 && bytes[5] & 0xF0 == 0xD0
    }

    /// True when nothing is bound to 127.0.0.1:port and nothing answers there either.
    public static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Same option ssh uses, so TIME_WAIT leftovers from a previous tunnel do not look like a conflict.
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = loopback(port)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        // SO_REUSEADDR lets a specific bind coexist with a wildcard listener, so also check nobody answers.
        return bound == 0 && withConnection(port: port, timeout: 0.3) { _ in true } == nil
    }

    public static func isListening(_ port: Int, timeout: Double = 0.3) async -> Bool {
        await Task.detached { withConnection(port: port, timeout: timeout) { _ in true } ?? false }.value
    }

    /// End-to-end check through the tunnel: the RDP server must answer the X.224 handshake.
    public static func rdpResponds(_ port: Int, timeout: Double = 3) async -> Bool {
        await Task.detached {
            withConnection(port: port, timeout: timeout) { fd in
                let sent = rdpRequest.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
                guard sent == rdpRequest.count else { return false }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, Int32(timeout * 1000)) == 1 else { return false }
                var buffer = [UInt8](repeating: 0, count: 64)
                let count = recv(fd, &buffer, buffer.count, 0)
                return count > 0 && isRDPResponse(Array(buffer.prefix(count)))
            } ?? false
        }.value
    }

    private static func loopback(_ port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(clamping: port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return address
    }

    private static func withConnection<T>(port: Int, timeout: Double, _ body: (Int32) -> T) -> T? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var address = loopback(port)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { return nil }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, Int32(timeout * 1000)) == 1 else { return nil }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return nil }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return body(fd)
    }
}

/// PIDs of tunnels we launched, so a crashed app can clean up its own orphans on the next launch.
public struct TunnelRecords: Sendable {
    public struct Entry: Codable, Equatable, Sendable { public let pid: Int32; public let command: String }
    public typealias Inspector = @Sendable (Int32) -> (parent: Int32, command: String)?
    let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
    func save(_ entries: [Entry]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
    func add(_ entry: Entry) { save(load().filter { $0.pid != entry.pid } + [entry]) }
    func remove(_ pid: Int32) { save(load().filter { $0.pid != pid }) }

    /// Kills only processes that were reparented to launchd and still run the exact command we recorded,
    /// so a recycled PID or anyone else's ssh is never touched.
    @discardableResult
    public func reapOrphans(inspect: Inspector = TunnelRecords.inspect, kill terminate: @Sendable (Int32) -> Void = { _ = kill($0, SIGTERM) }) -> [Int32] {
        var reaped: [Int32] = []
        for entry in load() {
            guard let info = inspect(entry.pid), info.parent == 1, info.command == entry.command else { continue }
            terminate(entry.pid)
            reaped.append(entry.pid)
        }
        save([])
        return reaped
    }

    public static let inspect: Inspector = { pid in
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-o", "ppid=,command=", "-p", String(pid)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, let space = line.firstIndex(of: " "), let parent = Int32(line[..<space]) else { return nil }
        return (parent, line[space...].trimmingCharacters(in: .whitespaces))
    }
}

/// One supervised tunnel per VM. Concurrent `ensure` calls for the same VM share a single launch.
public final class TunnelManager: @unchecked Sendable {
    public struct Environment: Sendable {
        public var launch: @Sendable (_ arguments: [String], _ onExit: @escaping @Sendable () -> Void) throws -> TunnelProcess
        public var isPortFree: @Sendable (Int) -> Bool
        public var isListening: @Sendable (Int) async -> Bool
        public var sleep: @Sendable (Duration) async throws -> Void
        public var readinessTimeout: Duration

        public init(launch: @escaping @Sendable ([String], @escaping @Sendable () -> Void) throws -> TunnelProcess,
                    isPortFree: @escaping @Sendable (Int) -> Bool, isListening: @escaping @Sendable (Int) async -> Bool,
                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                    readinessTimeout: Duration = .seconds(15)) {
            self.launch = launch; self.isPortFree = isPortFree; self.isListening = isListening
            self.sleep = sleep; self.readinessTimeout = readinessTimeout
        }

        public static let live = Environment(
            launch: { try SSHTunnelProcess(arguments: $0, onExit: $1) },
            isPortFree: { NetworkProbe.isPortFree($0) },
            isListening: { await NetworkProbe.isListening($0) })
    }

    private struct Active { let spec: TunnelSpec; let process: TunnelProcess }
    private struct Pending { let spec: TunnelSpec; let id: UUID; let task: Task<Void, Error> }
    private let lock = NSLock()
    private var active: [String: Active] = [:]
    private var pending: [String: Pending] = [:]
    private let environment: Environment
    private let records: TunnelRecords?
    private let onChange: @Sendable () -> Void

    public init(environment: Environment = .live, records: TunnelRecords? = nil, onChange: @escaping @Sendable () -> Void = {}) {
        self.environment = environment; self.records = records; self.onChange = onChange
    }

    public func spec(for key: String) -> TunnelSpec? {
        lock.lock(); defer { lock.unlock() }
        guard let tunnel = active[key], tunnel.process.isRunning else { return nil }
        return tunnel.spec
    }

    public func ensure(_ key: String, spec: TunnelSpec, connection: Connection) async throws {
        enum Plan { case reuse, join(Task<Void, Error>), launch(UUID, Task<Void, Error>, stale: TunnelProcess?) }
        let plan: Plan = lock.withLock {
            if let tunnel = active[key], tunnel.spec == spec, tunnel.process.isRunning { return .reuse }
            if let launch = pending[key], launch.spec == spec { return .join(launch.task) }
            let stale = active.removeValue(forKey: key)?.process
            pending[key]?.task.cancel()
            let id = UUID()
            let task = Task { try await self.launch(key, spec: spec, connection: connection) }
            pending[key] = Pending(spec: spec, id: id, task: task)
            return .launch(id, task, stale: stale)
        }
        switch plan {
        case .reuse: return
        case .join(let task): try await task.value
        case .launch(let id, let task, let stale):
            if let stale { retire(stale) }
            defer { lock.withLock { if pending[key]?.id == id { pending[key] = nil } } }
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
    }

    public func stop(_ key: String) {
        lock.lock()
        let tunnel = active.removeValue(forKey: key)
        pending.removeValue(forKey: key)?.task.cancel()
        lock.unlock()
        if let tunnel { retire(tunnel.process) }
        onChange()
    }

    /// Synchronous so it can run from `applicationWillTerminate`.
    public func stopAll() {
        lock.lock()
        let tunnels = active.values.map(\.process)
        active.removeAll()
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
        lock.unlock()
        tunnels.forEach(retire)
    }

    private func retire(_ process: TunnelProcess) {
        process.terminate()
        records?.remove(process.pid)
    }

    private func launch(_ key: String, spec: TunnelSpec, connection: Connection) async throws {
        let ownConflict = lock.withLock {
            active.contains { $0.key != key && $0.value.spec.localPort == spec.localPort && $0.value.process.isRunning }
        }
        guard !ownConflict, environment.isPortFree(spec.localPort) else { throw VMError.portInUse(spec.localPort) }
        let arguments = spec.arguments(via: connection)
        let box = ProcessBox()
        let process = try environment.launch(arguments) { [weak self] in self?.exited(key, pid: box.pid) }
        box.pid = process.pid
        records?.add(.init(pid: process.pid, command: (["/usr/bin/ssh"] + arguments).joined(separator: " ")))
        do {
            let attempts = max(1, Int(environment.readinessTimeout / .milliseconds(100)))
            for _ in 0..<attempts {
                try Task.checkCancellation()
                guard process.isRunning else { throw VMError.tunnelFailed(Self.summary(process.errorOutput)) }
                if await environment.isListening(spec.localPort) {
                    try Task.checkCancellation()
                    lock.withLock { active[key] = Active(spec: spec, process: process) }
                    onChange()
                    return
                }
                try await environment.sleep(.milliseconds(100))
            }
            throw VMError.tunnelFailed("o SSH não abriu a porta local a tempo.")
        } catch {
            retire(process)
            throw error
        }
    }

    private func exited(_ key: String, pid: Int32) {
        lock.lock()
        if active[key]?.process.pid == pid { active[key] = nil }
        lock.unlock()
        records?.remove(pid)
        onChange()
    }

    static func summary(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // ssh follows a bind failure with generic lines; the bind line is the useful one.
        guard let line = lines.first(where: { $0.contains("Address already in use") }) ?? lines.last else { return "o SSH encerrou sem detalhes." }
        return String(line.prefix(300))
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = 0
    var pid: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
