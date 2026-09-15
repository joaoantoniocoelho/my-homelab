import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
    public let error: String
}

private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

private final class CapturedData: @unchecked Sendable {
    var data = Data()
    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count < 2_000_000 { data.append(chunk.prefix(2_000_000 - data.count)) }
        }
    }
}

public enum ProcessRunner {
    public static func run(executable: String = "/usr/bin/ssh", arguments: [String], timeout: Double = 15) async throws -> CommandResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler(operation: {
            let result: CommandResult = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process(), stdout = Pipe(), stderr = Pipe()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.standardOutput = stdout; process.standardError = stderr
                    process.standardInput = FileHandle.nullDevice
                    do { try control.launch(process) } catch { continuation.resume(throwing: error); return }
                    let deadline = DispatchWorkItem { control.cancel() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    let out = CapturedData(), err = CapturedData(), readers = DispatchGroup()
                    readers.enter()
                    DispatchQueue.global().async { out.drain(stdout.fileHandleForReading); readers.leave() }
                    readers.enter()
                    DispatchQueue.global().async { err.drain(stderr.fileHandleForReading); readers.leave() }
                    process.waitUntilExit()
                    readers.wait()
                    deadline.cancel()
                    let error = String(decoding: err.data, as: UTF8.self)
                    continuation.resume(returning: CommandResult(status: process.terminationStatus,
                        output: String(decoding: out.data, as: UTF8.self),
                        error: process.terminationReason == .uncaughtSignal ? "A conexão foi interrompida ou excedeu o tempo limite. \(error)" : error))
                }
            }
            try Task.checkCancellation()
            return result
        }, onCancel: { control.cancel() })
    }
}
