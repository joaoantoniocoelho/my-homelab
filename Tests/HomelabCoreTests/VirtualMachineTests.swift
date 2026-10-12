import Darwin
import XCTest
@testable import HomelabCore

private func framed(_ json: String) -> String { "banner\n__HL_JSON_BEGIN__\n\(json)\n__HL_JSON_END__\n" }

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    var all: [String] { lock.withLock { items } }
    func count(_ item: String) -> Int { all.filter { $0 == item }.count }
}

final class VirtualMachineModelTests: XCTestCase {
    func testInventoryDecodingStatesAndReadiness() throws {
        let json = #"{"available":true,"error":null,"machines":[{"name":"kali","state":"running","vcpus":4,"memory":4294967296,"disk":128849018880,"address":"192.168.122.81","sshReady":true,"rdpReady":false},{"name":"other","state":"weird","vcpus":null,"memory":null,"disk":null,"address":null,"sshReady":null,"rdpReady":null}]}"#
        let inventory = try LibvirtClient.decode(VMInventory.self, from: framed(json))
        XCTAssertTrue(inventory.available)
        let kali = inventory.machines[0]
        XCTAssertEqual(kali.state, .running)
        XCTAssertEqual(kali.vcpus, 4)
        XCTAssertTrue(kali.guestReady)
        XCTAssertEqual(inventory.machines[1].state, .nostate)
        XCTAssertFalse(VirtualMachine(name: "a", state: .running, sshReady: false, rdpReady: false).guestReady)
        XCTAssertFalse(VirtualMachine(name: "a", state: .shutoff, sshReady: true).guestReady)
        XCTAssertTrue(VirtualMachine(name: "a", state: .crashed).isOff)
        XCTAssertThrowsError(try LibvirtClient.decode(VMInventory.self, from: json))
    }

    func testConfigValidationDefaultsAndDecoding() throws {
        XCTAssertTrue(VirtualMachineConfig.isSafeName("kali"))
        XCTAssertTrue(VirtualMachineConfig.isSafeName("ubuntu-24.04_server"))
        for unsafe in ["-c", "a;b", "a b", "$(x)", "", "a'b", "kali\n"] { XCTAssertFalse(VirtualMachineConfig.isSafeName(unsafe), unsafe) }
        XCTAssertTrue(VirtualMachineConfig.isValidHost("192.168.122.81"))
        XCTAssertTrue(VirtualMachineConfig.isValidHost("kali.lan"))
        for bad in ["-oProxyCommand=x", "1.2.3.4;id", "a b", ""] { XCTAssertFalse(VirtualMachineConfig.isValidHost(bad), bad) }

        let first = VirtualMachineConfig.makeDefault(name: "kali", existing: [])
        XCTAssertEqual(first.localPort, 3390)
        XCTAssertEqual(first.rdpPort, 3389)
        XCTAssertEqual(first.rdpClient, VirtualMachineConfig.windowsApp)
        XCTAssertEqual(VirtualMachineConfig.makeDefault(name: "debian", existing: [first]).localPort, 3391)

        XCTAssertNotNil(VirtualMachineConfig(name: "kali", guestUser: "-oX").validationError)
        XCTAssertNotNil(VirtualMachineConfig(name: "kali", guestAddress: "1.2.3.4 -L").validationError)
        XCTAssertNotNil(VirtualMachineConfig(name: "kali", localPort: 80).validationError)
        XCTAssertNotNil(VirtualMachineConfig(name: "kali", rdpPort: 70000).validationError)
        XCTAssertNil(VirtualMachineConfig(name: "kali", guestUser: "joaoac").validationError)

        let decoded = try JSONDecoder().decode(VirtualMachineConfig.self, from: Data(#"{"name":"kali","guestUser":"joaoac"}"#.utf8))
        XCTAssertEqual(decoded, VirtualMachineConfig(name: "kali", guestUser: "joaoac"))
        XCTAssertEqual(decoded.display, .fullHD)
    }

    func testDisplayRoundTripsAndToleratesUnknownValues() throws {
        let saved = VirtualMachineConfig(name: "kali", display: .fullScreen)
        XCTAssertEqual(try JSONDecoder().decode(VirtualMachineConfig.self, from: try JSONEncoder().encode(saved)), saved)
        let unknown = try JSONDecoder().decode(VirtualMachineConfig.self, from: Data(#"{"name":"kali","localPort":3395,"display":"8k"}"#.utf8))
        XCTAssertEqual(unknown.display, .fullHD)
        XCTAssertEqual(unknown.localPort, 3395)
    }

    func testEndpointPrefersValidatedOverride() {
        let running = VirtualMachine(name: "kali", state: .running, address: "192.168.122.81")
        XCTAssertEqual(VirtualMachineConfig(name: "kali").endpoint(for: running), "192.168.122.81")
        XCTAssertEqual(VirtualMachineConfig(name: "kali", guestAddress: "10.0.0.5").endpoint(for: running), "10.0.0.5")
        XCTAssertNil(VirtualMachineConfig(name: "kali").endpoint(for: VirtualMachine(name: "kali", state: .running, address: "-oProxyCommand=x")))
        XCTAssertNil(VirtualMachineConfig(name: "kali").endpoint(for: nil))
    }

    func testGuestSSHJumpsThroughHomelabWithoutWeakeningTrust() {
        let config = VirtualMachineConfig(name: "kali", guestUser: "joaoac")
        let jump = Connection(host: "192.168.0.250", user: "joaoac", port: 22)
        let batch = config.guestArguments(address: "192.168.122.81", via: jump, interactive: false, command: "true")
        XCTAssertEqual(Array(batch.suffix(5)), ["-J", "joaoac@192.168.0.250:22", "--", "joaoac@192.168.122.81", "true"])
        XCTAssertTrue(batch.contains("BatchMode=yes"))
        XCTAssertFalse(batch.contains { $0.contains("StrictHostKeyChecking") })
        let interactive = config.guestArguments(address: "192.168.122.81", via: Connection(host: "homelab"), interactive: true)
        XCTAssertTrue(interactive.contains("-tt"))
        XCTAssertTrue(interactive.contains("homelab:22"))
        XCTAssertEqual(Connection(host: "fe80::1", port: 2222).jumpSpecification, "[fe80::1]:2222")
    }

    func testTunnelBindsLoopbackAndFailsFast() {
        let args = TunnelSpec(localPort: 3390, remoteHost: "192.168.122.81", remotePort: 3389).arguments(via: Connection(host: "homelab", port: 2222))
        XCTAssertEqual(args.firstIndex(of: "-L").map { args[$0 + 1] }, "127.0.0.1:3390:192.168.122.81:3389")
        for option in ["ExitOnForwardFailure=yes", "BatchMode=yes", "ControlMaster=no", "ControlPath=none", "GatewayPorts=no"] {
            XCTAssertTrue(args.contains(option), option)
        }
        XCTAssertTrue(args.contains("-N"))
        XCTAssertEqual(Array(args.suffix(2)), ["--", "homelab"])
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")
        XCTAssertEqual(TunnelSpec(localPort: 1, remoteHost: "fd00::5", remotePort: 2).forward, "127.0.0.1:1:[fd00::5]:2")
    }

    func testRDPFileHasNoCredentials() throws {
        let contents = RDPFile.contents(host: "127.0.0.1", port: 3390, username: "joaoac")
        XCTAssertTrue(contents.contains("full address:s:127.0.0.1:3390"))
        XCTAssertTrue(contents.contains("username:s:joaoac"))
        XCTAssertFalse(contents.lowercased().contains("password"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try RDPFile.write(name: "kali", port: 3390, username: "", in: directory)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertThrowsError(try RDPFile.write(name: "../evil", port: 1, username: "", in: directory))
    }

    func testRDPFileUsesFixedWindowByDefault() throws {
        let lines = RDPFile.contents(host: "127.0.0.1", port: 3390, username: "").components(separatedBy: "\r\n")
        for line in ["screen mode id:i:1", "desktopwidth:i:1920", "desktopheight:i:1080", "dynamic resolution:i:0",
                     "smart sizing:i:1", "session bpp:i:32"] {
            XCTAssertTrue(lines.contains(line), line)
        }
        XCTAssertFalse(lines.contains { $0.hasPrefix("username:") })

        let small = RDPFile.contents(host: "127.0.0.1", port: 3390, username: "", display: .hd).components(separatedBy: "\r\n")
        XCTAssertTrue(small.contains("desktopwidth:i:1280") && small.contains("desktopheight:i:720"))

        let full = RDPFile.contents(host: "127.0.0.1", port: 3390, username: "", display: .fullScreen).components(separatedBy: "\r\n")
        XCTAssertTrue(full.contains("screen mode id:i:2"))
        XCTAssertTrue(full.contains("dynamic resolution:i:1"))
        XCTAssertFalse(full.contains { $0.hasPrefix("desktopwidth:") })

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try RDPFile.write(name: "kali", port: 3390, username: "", display: .qhd, in: directory)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("desktopwidth:i:2560"))
    }

    func testGuestPowerOffClassification() {
        XCTAssertEqual(GuestClient.classify(CommandResult(status: 0, output: "", error: "")), .accepted)
        XCTAssertEqual(GuestClient.classify(CommandResult(status: 255, output: "", error: "Connection to 192.168.122.81 closed by remote host.")), .accepted)
        XCTAssertEqual(GuestClient.classify(CommandResult(status: 1, output: "", error: "sudo: a password is required")), .authorizationRequired)
        XCTAssertEqual(GuestClient.classify(CommandResult(status: 1, output: "", error: "Failed: Interactive authentication required.")), .authorizationRequired)
        XCTAssertEqual(GuestClient.classify(CommandResult(status: 255, output: "", error: "Host key verification failed.")), .failed("Host key verification failed."))
    }
}

final class LibvirtClientTests: XCTestCase {
    private let connection = Connection(host: "homelab")

    func testInventoryRunsOneQuotedSSHCommand() async throws {
        let calls = Calls()
        let client = LibvirtClient(connection: connection) { executable, args, _ in
            calls.add(executable); calls.add(args.joined(separator: "\u{1}"))
            return CommandResult(status: 0, output: framed(#"{"available":true,"error":null,"machines":[]}"#), error: "")
        }
        let config = VirtualMachineConfig(name: "kali", guestAddress: "10.0.0.5")
        let inventory = try await client.inventory([config, VirtualMachineConfig(name: "bad;name")])
        XCTAssertTrue(inventory.machines.isEmpty)
        XCTAssertEqual(calls.all[0], "/usr/bin/ssh")
        let args = calls.all[1].components(separatedBy: "\u{1}")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        let command = try XCTUnwrap(args.last)
        XCTAssertTrue(command.hasPrefix("python3 -c '"))
        XCTAssertTrue(command.contains(" 'qemu:///system' 'inventory' '{"))
        XCTAssertTrue(command.contains(#""address":"10.0.0.5""#))
        XCTAssertFalse(command.contains("bad;name"), "invalid configs are not forwarded")
    }

    func testQuotedArgumentsSurviveAShell() async throws {
        let command = try LibvirtClient.command(["status", "it's; $(rm -rf ~)"])
        let echoed = command.replacingOccurrences(of: "python3 -c ", with: "printf '%s\\n' ")
        let result = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", echoed])
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertTrue(lines.contains("it's; $(rm -rf ~)"))
        XCTAssertTrue(lines.contains("qemu:///system"))
    }

    func testUnsafeNamesNeverReachTheServer() async {
        let calls = Calls()
        let client = LibvirtClient(connection: connection) { _, _, _ in calls.add("ran"); return CommandResult(status: 0, output: "", error: "") }
        for action in [{ try await client.start("-x") }, { try await client.forceStop("a;b") }, { _ = try await client.status(VirtualMachineConfig(name: "$(id)")) }] {
            do { try await action(); XCTFail("should reject") } catch { XCTAssertTrue(error is VMError) }
        }
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testFailuresAreReportedClearly() async throws {
        func client(_ status: Int32, _ output: String, _ error: String = "") -> LibvirtClient {
            LibvirtClient(connection: connection) { _, _, _ in CommandResult(status: status, output: output, error: error) }
        }
        do { _ = try await client(255, "", "ssh: connect to host homelab port 22: Connection refused").inventory([]); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .commandFailed("ssh: connect to host homelab port 22: Connection refused"))
        }
        let unavailable = client(0, framed(#"{"available":false,"error":"failed to connect to the hypervisor","machines":[]}"#))
        let inventory = try await unavailable.inventory([])
        XCTAssertFalse(inventory.available)
        do { _ = try await unavailable.status(VirtualMachineConfig(name: "kali")); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .libvirtUnavailable("failed to connect to the hypervisor"))
        }
        do { _ = try await client(0, framed(#"{"available":true,"error":null,"machines":[]}"#)).status(VirtualMachineConfig(name: "kali")); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .notFound("kali"))
        }
        do { try await client(0, framed(#"{"ok":false,"error":"permission denied"}"#)).start("kali"); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .commandFailed("permission denied"))
        }
        try await client(0, framed(#"{"ok":true,"error":null}"#)).requestShutdown("kali")
    }

    func testVMScriptIsBundled() throws {
        XCTAssertTrue(try LibvirtClient.command(["inventory", "{}"]).hasPrefix("python3 -c '\"\"\"Libvirt helper"))
    }
}

/// Minimal TCP server on loopback for probe tests.
private final class LoopbackServer: @unchecked Sendable {
    let fd: Int32
    let port: Int
    init(reply: [UInt8]?) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        guard bound == 0, listen(fd, 4) == 0 else { throw VMError.commandFailed("listen failed") }
        withUnsafeMutablePointer(to: &address) { _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        self.fd = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 64)
                _ = recv(client, &buffer, buffer.count, 0)
                if let reply { _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) } }
                close(client)
            }
        }
    }
    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}

final class NetworkProbeTests: XCTestCase {
    func testRDPResponseValidation() {
        XCTAssertEqual(NetworkProbe.rdpRequest.count, 19)
        XCTAssertTrue(NetworkProbe.isRDPResponse([0x03, 0x00, 0x00, 0x13, 0x0e, 0xd0, 0x00]))
        XCTAssertFalse(NetworkProbe.isRDPResponse(Array("SSH-2.0-OpenSSH".utf8)))
        XCTAssertFalse(NetworkProbe.isRDPResponse([0x03, 0x00]))
    }

    func testProbesAgainstRealSockets() async throws {
        let rdp = try LoopbackServer(reply: [0x03, 0x00, 0x00, 0x13, 0x0e, 0xd0, 0x00, 0x00, 0x12, 0x34, 0x00])
        let other = try LoopbackServer(reply: Array("HTTP/1.1 400\r\n".utf8))
        defer { rdp.stop(); other.stop() }
        let rdpResponds = await NetworkProbe.rdpResponds(rdp.port, timeout: 1)
        let otherResponds = await NetworkProbe.rdpResponds(other.port, timeout: 1)
        XCTAssertTrue(rdpResponds)
        XCTAssertFalse(otherResponds)
        let listening = await NetworkProbe.isListening(rdp.port)
        XCTAssertTrue(listening)
        XCTAssertFalse(NetworkProbe.isPortFree(rdp.port), "a port with a listener is a conflict")
        let freePort = other.port
        other.stop()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(NetworkProbe.isPortFree(freePort))
        let closedResponds = await NetworkProbe.rdpResponds(freePort, timeout: 0.5)
        XCTAssertFalse(closedResponds)
    }
}

final class FakeTunnelProcess: TunnelProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Bool
    let pid: Int32
    let errorOutput: String
    var onExit: (@Sendable () -> Void)?
    init(pid: Int32, alive: Bool = true, errorOutput: String = "") { self.pid = pid; self.alive = alive; self.errorOutput = errorOutput }
    var isRunning: Bool { lock.withLock { alive } }
    func terminate() { let wasAlive = lock.withLock { let was = alive; alive = false; return was }; if wasAlive { onExit?() } }
}

final class TunnelManagerTests: XCTestCase {
    private let connection = Connection(host: "homelab")
    private let spec = TunnelSpec(localPort: 3390, remoteHost: "192.168.122.81", remotePort: 3389)

    private func manager(_ calls: Calls, processes: FakeProcesses, portFree: Bool = true, listening: Bool = true,
                         records: TunnelRecords? = nil) -> TunnelManager {
        TunnelManager(environment: .init(
            launch: { args, onExit in
                calls.add("launch " + args.joined(separator: " "))
                let process = processes.next(); process.onExit = onExit; return process
            },
            isPortFree: { _ in portFree },
            isListening: { _ in try? await Task.sleep(for: .milliseconds(20)); return listening },
            sleep: { _ in await Task.yield() },
            readinessTimeout: .milliseconds(500)), records: records)
    }

    final class FakeProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [FakeTunnelProcess] = []
        let alive: Bool, stderr: String
        init(alive: Bool = true, stderr: String = "") { self.alive = alive; self.stderr = stderr }
        func next() -> FakeTunnelProcess {
            lock.withLock { let p = FakeTunnelProcess(pid: Int32(1000 + made.count), alive: alive, errorOutput: stderr); made.append(p); return p }
        }
        var all: [FakeTunnelProcess] { lock.withLock { made } }
    }

    func testConcurrentEnsureLaunchesOnceAndReuses() async throws {
        let calls = Calls(), processes = FakeProcesses()
        let tunnels = manager(calls, processes: processes)
        async let a: Void = tunnels.ensure("kali", spec: spec, connection: connection)
        async let b: Void = tunnels.ensure("kali", spec: spec, connection: connection)
        _ = try await (a, b)
        try await tunnels.ensure("kali", spec: spec, connection: connection)
        XCTAssertEqual(calls.all.filter { $0.hasPrefix("launch") }.count, 1)
        XCTAssertTrue(calls.all[0].contains("-L 127.0.0.1:3390:192.168.122.81:3389"))
        XCTAssertEqual(tunnels.spec(for: "kali"), spec)
    }

    func testDeadTunnelIsReplacedAndStopTerminates() async throws {
        let calls = Calls(), processes = FakeProcesses()
        let tunnels = manager(calls, processes: processes)
        try await tunnels.ensure("kali", spec: spec, connection: connection)
        processes.all[0].terminate()
        XCTAssertNil(tunnels.spec(for: "kali"), "an exited ssh is not reported as active")
        try await tunnels.ensure("kali", spec: spec, connection: connection)
        XCTAssertEqual(processes.all.count, 2)
        tunnels.stop("kali")
        XCTAssertFalse(processes.all[1].isRunning)
        XCTAssertNil(tunnels.spec(for: "kali"))
    }

    func testPortConflictsNeverLaunchOrKill() async {
        let calls = Calls(), processes = FakeProcesses()
        do { try await manager(calls, processes: processes, portFree: false).ensure("kali", spec: spec, connection: connection); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .portInUse(3390))
        }
        XCTAssertTrue(processes.all.isEmpty)

        let shared = manager(calls, processes: processes)
        try? await shared.ensure("kali", spec: spec, connection: connection)
        do { try await shared.ensure("debian", spec: TunnelSpec(localPort: 3390, remoteHost: "192.168.122.90", remotePort: 3389), connection: connection); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .portInUse(3390))
        }
        XCTAssertTrue(processes.all[0].isRunning, "the other VM's tunnel is untouched")
    }

    func testEarlyExitReportsSSHError() async {
        let processes = FakeProcesses(alive: false, stderr: "bind [127.0.0.1]:3390: Address already in use\nchannel_setup_fwd_listener_tcpip: cannot listen to port: 3390\nCould not request local forwarding.\n")
        do { try await manager(Calls(), processes: processes).ensure("kali", spec: spec, connection: connection); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .tunnelFailed("bind [127.0.0.1]:3390: Address already in use"))
        }
    }

    func testReadinessTimeoutAndCancellationCleanUp() async throws {
        let processes = FakeProcesses()
        let tunnels = manager(Calls(), processes: processes, listening: false)
        do { try await tunnels.ensure("kali", spec: spec, connection: connection); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .tunnelFailed("o SSH não abriu a porta local a tempo."))
        }
        XCTAssertFalse(processes.all[0].isRunning)

        let task = Task { try await tunnels.ensure("kali", spec: spec, connection: connection) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(processes.all[1].isRunning, "a cancelled launch leaves no ssh behind")
    }

    func testStopAllAndRecords() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let records = TunnelRecords(url: url)
        let processes = FakeProcesses()
        let tunnels = manager(Calls(), processes: processes, records: records)
        try await tunnels.ensure("kali", spec: spec, connection: connection)
        XCTAssertEqual(records.load().map(\.pid), [1000])
        XCTAssertTrue(records.load()[0].command.hasPrefix("/usr/bin/ssh -N "))
        tunnels.stopAll()
        XCTAssertFalse(processes.all[0].isRunning)
        XCTAssertTrue(records.load().isEmpty)
    }

    func testReaperOnlyKillsOurOwnOrphans() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let records = TunnelRecords(url: url)
        records.add(.init(pid: 10, command: "/usr/bin/ssh -N -L 127.0.0.1:3390:x:3389 -- homelab"))
        records.add(.init(pid: 11, command: "/usr/bin/ssh -N -L 127.0.0.1:3391:x:3389 -- homelab"))
        records.add(.init(pid: 12, command: "/usr/bin/ssh -N -L 127.0.0.1:3392:x:3389 -- homelab"))
        records.add(.init(pid: 13, command: "/usr/bin/ssh gone"))
        let killed = Calls()
        let reaped = records.reapOrphans(inspect: { pid in
            switch pid {
            case 10: return (1, "/usr/bin/ssh -N -L 127.0.0.1:3390:x:3389 -- homelab")   // our orphan
            case 11: return (1, "/usr/bin/ssh someone-else")                                // PID reused by another ssh
            case 12: return (4242, "/usr/bin/ssh -N -L 127.0.0.1:3392:x:3389 -- homelab")  // still has a live parent
            default: return nil
            }
        }, kill: { killed.add(String($0)) })
        XCTAssertEqual(reaped, [10])
        XCTAssertEqual(killed.all, ["10"])
        XCTAssertTrue(records.load().isEmpty)
    }

    func testRealProcessLifecycle() async throws {
        let exited = expectation(description: "exit")
        let process = try SSHTunnelProcess(executable: "/bin/sh", arguments: ["-c", "echo boom >&2; exec sleep 30"]) { exited.fulfill() }
        XCTAssertTrue(process.isRunning)
        try await Task.sleep(for: .milliseconds(200))
        process.terminate()
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(TunnelManager.summary(process.errorOutput), "boom")
    }
}

/// Scripted hypervisor for flow tests. `states` is consumed one status call at a time; the last one repeats.
private final class FakeHypervisor: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [VirtualMachine]
    let calls = Calls()
    var guestResult: GuestPowerResult = .accepted
    var desktopResponds = true
    var statusDelay: Duration = .zero

    init(_ states: [VirtualMachine]) { self.states = states }

    func status() -> VirtualMachine {
        lock.withLock { states.count > 1 ? states.removeFirst() : states[0] }
    }

    func dependencies() -> VMOperations.Dependencies {
        VMOperations.Dependencies(
            status: { _ in self.calls.add("status"); if self.statusDelay > .zero { try await Task.sleep(for: self.statusDelay) }; return self.status() },
            start: { self.calls.add("start \($0)") },
            requestShutdown: { self.calls.add("acpi \($0)") },
            forceStop: { self.calls.add("destroy \($0)") },
            guestPowerOff: { _, host in self.calls.add("guest \(host)"); return self.guestResult },
            openTunnel: { _, spec in self.calls.add("tunnel \(spec.forward)") },
            closeTunnel: { self.calls.add("close \($0)") },
            probeDesktop: { self.calls.add("probe \($0)"); return self.desktopResponds },
            launchClient: { self.calls.add("launch \($0.name)") },
            sleep: { _ in await Task.yield() })
    }
}

final class VMOperationsTests: XCTestCase {
    private let config = VirtualMachineConfig(name: "kali", guestUser: "joaoac")
    private let timing = VMOperations.Timing(poll: .seconds(2), boot: .seconds(10), shutdown: .seconds(6), authorizedShutdown: .seconds(6))
    private func vm(_ state: VMPowerState, ssh: Bool? = nil, rdp: Bool? = nil, address: String? = "192.168.122.81") -> VirtualMachine {
        VirtualMachine(name: "kali", state: state, address: state == .running ? address : nil, sshReady: ssh, rdpReady: rdp)
    }

    func testRunningVMIsReusedNotRestarted() async throws {
        let hv = FakeHypervisor([vm(.running, ssh: true, rdp: true)])
        let stages = Calls()
        try await VMOperations(dependencies: hv.dependencies(), timing: timing).perform(.openDesktop, config) { stages.add("\($0)") }
        XCTAssertEqual(hv.calls.all, ["status", "tunnel 127.0.0.1:3390:192.168.122.81:3389", "probe 3390", "launch kali"])
        XCTAssertEqual(stages.all, ["checking", "waitingForGuest", "openingTunnel", "verifyingDesktop", "launchingClient"])
    }

    func testShutOffVMStartsAndWaitsForRDPInsteadOfSleeping() async throws {
        let hv = FakeHypervisor([vm(.shutoff), vm(.running), vm(.running, ssh: false, rdp: false), vm(.running, ssh: true, rdp: false), vm(.running, ssh: true, rdp: true)])
        try await VMOperations(dependencies: hv.dependencies(), timing: timing).perform(.openDesktop, config)
        XCTAssertEqual(hv.calls.count("start kali"), 1)
        XCTAssertEqual(hv.calls.count("status"), 5)
        XCTAssertEqual(hv.calls.all.last, "launch kali")
    }

    func testGuestTimeoutsExplainWhatIsMissing() async {
        for (machine, expected) in [(vm(.running, ssh: true, rdp: false), VMError.guestTimeout(sshReady: true)),
                                    (vm(.running, ssh: false, rdp: false), .guestTimeout(sshReady: false)),
                                    (vm(.running, address: nil), .noAddress)] {
            let hv = FakeHypervisor([machine])
            do { try await VMOperations(dependencies: hv.dependencies(), timing: timing).perform(.openDesktop, config); XCTFail() } catch {
                XCTAssertEqual(error as? VMError, expected)
            }
            XCTAssertEqual(hv.calls.count("status"), 6, "bounded by boot timeout / poll interval")
            XCTAssertFalse(hv.calls.all.contains { $0.hasPrefix("tunnel") || $0.hasPrefix("launch") })
        }
    }

    func testUnreachableDesktopClosesTunnelAndNeverLaunches() async {
        let hv = FakeHypervisor([vm(.running, ssh: true, rdp: true)])
        hv.desktopResponds = false
        do { try await VMOperations(dependencies: hv.dependencies(), timing: timing).perform(.openDesktop, config); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .rdpUnreachable)
        }
        XCTAssertEqual(hv.calls.count("probe 3390"), 3)
        XCTAssertTrue(hv.calls.all.contains("close kali"))
        XCTAssertFalse(hv.calls.all.contains("launch kali"))
    }

    func testStatesThatMustNotBeStarted() async {
        for (state, expected) in [(VMPowerState.paused, VMError.paused), (.shutdown, .stillShuttingDown)] {
            let hv = FakeHypervisor([vm(state)])
            do { try await VMOperations(dependencies: hv.dependencies(), timing: timing).perform(.openDesktop, config); XCTFail() } catch {
                XCTAssertEqual(error as? VMError, expected)
            }
            XCTAssertEqual(hv.calls.count("start kali"), 0)
        }
    }

    func testDuplicateClicksJoinOneFlow() async throws {
        let hv = FakeHypervisor([vm(.shutoff), vm(.running, ssh: true, rdp: true)])
        hv.statusDelay = .milliseconds(30)
        let operations = VMOperations(dependencies: hv.dependencies(), timing: timing)
        async let first: Void = operations.perform(.openDesktop, config)
        async let second: Void = operations.perform(.openDesktop, config)
        async let third: Void = operations.perform(.openDesktop, config)
        _ = try await (first, second, third)
        XCTAssertEqual(hv.calls.count("start kali"), 1)
        XCTAssertEqual(hv.calls.all.filter { $0.hasPrefix("tunnel") }.count, 1)
        XCTAssertEqual(hv.calls.count("launch kali"), 1)
    }

    func testDifferentOperationWhileBusyIsRejected() async throws {
        let hv = FakeHypervisor([vm(.running, ssh: true, rdp: true)])
        hv.statusDelay = .milliseconds(100)
        let operations = VMOperations(dependencies: hv.dependencies(), timing: timing)
        let desktop = Task { try await operations.perform(.openDesktop, config) }
        try await Task.sleep(for: .milliseconds(20))
        do { try await operations.perform(.shutDown, config); XCTFail() } catch { XCTAssertEqual(error as? VMError, .busy("kali")) }
        try await desktop.value
    }

    func testCancellationStopsTheFlow() async throws {
        let hv = FakeHypervisor([vm(.running, ssh: false, rdp: false)])
        hv.statusDelay = .milliseconds(20)
        let operations = VMOperations(dependencies: hv.dependencies(), timing: VMOperations.Timing(poll: .seconds(1), boot: .seconds(1000)))
        let task = Task { try await operations.perform(.openDesktop, config) }
        try await Task.sleep(for: .milliseconds(80))
        await operations.cancel("kali")
        do { try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(hv.calls.all.contains { $0.hasPrefix("tunnel") || $0.hasPrefix("launch") })
        // The slot is free again afterwards.
        let fresh = FakeHypervisor([vm(.shutoff)])
        try await VMOperations(dependencies: fresh.dependencies(), timing: timing).perform(.shutDown, config)
    }

    func testShutdownGoesThroughTheGuestFirst() async throws {
        let hv = FakeHypervisor([vm(.running, ssh: true, rdp: true), vm(.running, ssh: false), vm(.shutoff)])
        try await VMOperations(dependencies: hv.dependencies(), timing: timing).perform(.shutDown, config)
        XCTAssertTrue(hv.calls.all.contains("guest 192.168.122.81"))
        XCTAssertFalse(hv.calls.all.contains("acpi kali"))
        XCTAssertFalse(hv.calls.all.contains("destroy kali"), "graceful shutdown never destroys")
        XCTAssertEqual(hv.calls.all.last, "close kali")
    }

    func testShutdownNeedingSudoStopsAndAsks() async {
        let hv = FakeHypervisor([vm(.running, ssh: true)])
        hv.guestResult = .authorizationRequired
        do { try await VMOperations(dependencies: hv.dependencies(), timing: timing).perform(.shutDown, config); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .shutdownNeedsAuthorization)
        }
        XCTAssertFalse(hv.calls.all.contains("acpi kali"))
        XCTAssertFalse(hv.calls.all.contains("destroy kali"))
    }

    func testShutdownFallsBackToACPI() async throws {
        let failing = FakeHypervisor([vm(.running, ssh: true), vm(.shutoff)])
        failing.guestResult = .failed("Host key verification failed.")
        try await VMOperations(dependencies: failing.dependencies(), timing: timing).perform(.shutDown, config)
        XCTAssertTrue(failing.calls.all.contains("acpi kali"))

        let noSSH = FakeHypervisor([vm(.running, ssh: false), vm(.shutoff)])
        try await VMOperations(dependencies: noSSH.dependencies(), timing: timing).perform(.shutDown, config)
        XCTAssertFalse(noSSH.calls.all.contains { $0.hasPrefix("guest") })
        XCTAssertTrue(noSSH.calls.all.contains("acpi kali"))
    }

    func testIgnoredShutdownTimesOutWithoutForcing() async {
        let hv = FakeHypervisor([vm(.running, ssh: false)])
        do { try await VMOperations(dependencies: hv.dependencies(), timing: timing).perform(.shutDown, config); XCTFail() } catch {
            XCTAssertEqual(error as? VMError, .shutdownTimedOut)
        }
        XCTAssertFalse(hv.calls.all.contains("destroy kali"))
    }

    func testAlreadyOffAndRestartAndForceStop() async throws {
        let off = FakeHypervisor([vm(.shutoff)])
        try await VMOperations(dependencies: off.dependencies(), timing: timing).perform(.shutDown, config)
        XCTAssertFalse(off.calls.all.contains { $0.hasPrefix("guest") || $0.hasPrefix("acpi") })

        let restart = FakeHypervisor([vm(.running, ssh: true), vm(.shutoff), vm(.shutoff), vm(.running), vm(.running, ssh: true)])
        try await VMOperations(dependencies: restart.dependencies(), timing: timing).perform(.restart, config)
        let order = restart.calls.all.filter { $0.hasPrefix("guest") || $0.hasPrefix("start") }
        XCTAssertEqual(order, ["guest 192.168.122.81", "start kali"])

        let force = FakeHypervisor([vm(.running), vm(.shutoff)])
        try await VMOperations(dependencies: force.dependencies(), timing: timing).perform(.forceStop, config)
        XCTAssertTrue(force.calls.all.contains("destroy kali"))
    }

    func testInvalidConfigurationIsRejectedUpFront() async {
        let hv = FakeHypervisor([vm(.running)])
        do { try await VMOperations(dependencies: hv.dependencies()).perform(.openDesktop, VirtualMachineConfig(name: "kali", localPort: 22)); XCTFail() } catch {
            XCTAssertTrue(error is VMError)
        }
        XCTAssertTrue(hv.calls.all.isEmpty)
    }
}
