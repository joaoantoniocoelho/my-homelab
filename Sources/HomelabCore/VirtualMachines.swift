import Foundation

public typealias CommandExecutor = @Sendable (_ executable: String, _ arguments: [String], _ timeout: Double) async throws -> CommandResult

public enum VMPowerState: String, Sendable, Equatable {
    case running, blocked, paused, shutdown, shutoff, crashed, pmsuspended, nostate
}

public struct VirtualMachine: Decodable, Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let state: VMPowerState
    public let vcpus: Int?
    public let memory: Double?
    public let disk: Double?
    public let address: String?
    public let sshReady: Bool?
    public let rdpReady: Bool?

    public init(name: String, state: VMPowerState, vcpus: Int? = nil, memory: Double? = nil, disk: Double? = nil,
                address: String? = nil, sshReady: Bool? = nil, rdpReady: Bool? = nil) {
        self.name = name; self.state = state; self.vcpus = vcpus; self.memory = memory; self.disk = disk
        self.address = address; self.sshReady = sshReady; self.rdpReady = rdpReady
    }

    enum CodingKeys: String, CodingKey { case name, state, vcpus, memory, disk, address, sshReady, rdpReady }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        state = VMPowerState(rawValue: try c.decode(String.self, forKey: .state)) ?? .nostate
        vcpus = try c.decodeIfPresent(Int.self, forKey: .vcpus)
        memory = try c.decodeIfPresent(Double.self, forKey: .memory)
        disk = try c.decodeIfPresent(Double.self, forKey: .disk)
        address = try c.decodeIfPresent(String.self, forKey: .address)
        sshReady = try c.decodeIfPresent(Bool.self, forKey: .sshReady)
        rdpReady = try c.decodeIfPresent(Bool.self, forKey: .rdpReady)
    }

    public var isRunning: Bool { state == .running || state == .blocked }
    public var isOff: Bool { state == .shutoff || state == .crashed }
    /// A running domain is not a usable guest: readiness comes from its SSH or RDP services answering.
    public var guestReady: Bool { isRunning && (sshReady == true || rdpReady == true) }
}

public struct VMInventory: Decodable, Sendable {
    public let available: Bool
    public let error: String?
    public let machines: [VirtualMachine]
}

public enum VMError: LocalizedError, Equatable {
    case libvirtUnavailable(String)
    case commandFailed(String)
    case notFound(String)
    case invalidConfiguration(String)
    case busy(String)
    case paused
    case stillShuttingDown
    case noAddress
    case guestTimeout(sshReady: Bool)
    case rdpUnreachable
    case portInUse(Int)
    case tunnelFailed(String)
    case clientUnavailable(String)
    case shutdownNeedsAuthorization
    case shutdownTimedOut

    public var errorDescription: String? {
        switch self {
        case .libvirtUnavailable(let detail): return "Libvirt indisponível: \(detail)"
        case .commandFailed(let detail): return detail
        case .notFound(let name): return "A máquina virtual \(name) não foi encontrada no libvirt."
        case .invalidConfiguration(let detail): return "Configuração inválida: \(detail)"
        case .busy(let name): return "\(name) já está executando outra operação."
        case .paused: return "A VM está pausada. Retome-a pelo virsh antes de conectar."
        case .stillShuttingDown: return "A VM está desligando. Aguarde até ela parar antes de ligá-la de novo."
        case .noAddress: return "A VM está ligada, mas ainda não tem endereço de rede (lease DHCP/ARP). Configure o endereço manualmente se ela usar IP estático."
        case .guestTimeout(let sshReady):
            return sshReady ? "O sistema convidado respondeu por SSH, mas o desktop remoto (XRDP) não ficou disponível. Verifique o serviço xrdp no convidado."
                : "O sistema convidado não ficou pronto a tempo: SSH e RDP não responderam."
        case .rdpUnreachable: return "O túnel foi aberto, mas o RDP não respondeu através dele."
        case .portInUse(let port): return "A porta local \(port) já está em uso por outro processo. Encerre-o ou escolha outra porta nas configurações da VM."
        case .tunnelFailed(let detail): return "Não foi possível abrir o túnel SSH: \(detail)"
        case .clientUnavailable(let name): return "Cliente de desktop remoto indisponível: \(name)."
        case .shutdownNeedsAuthorization: return "O convidado exige a senha do sudo para desligar."
        case .shutdownTimedOut: return "A VM não desligou a tempo. O convidado pode ter ignorado o pedido."
        }
    }
}

/// Remote session size. A fixed size keeps the guest encoding a known number of pixels, whatever the Mac's screen.
public enum RDPDisplay: String, Codable, CaseIterable, Sendable, Identifiable {
    case hd = "1280x720", hdPlus = "1600x900", fullHD = "1920x1080", qhd = "2560x1440", fullScreen

    public var id: String { rawValue }
    public var size: (width: Int, height: Int)? {
        switch self {
        case .hd: return (1280, 720)
        case .hdPlus: return (1600, 900)
        case .fullHD: return (1920, 1080)
        case .qhd: return (2560, 1440)
        case .fullScreen: return nil
        }
    }
    public var title: String {
        guard let size else { return "Tela cheia" }
        return "\(size.width) × \(size.height)"
    }
}

/// Per-VM settings. The libvirt domain name is the identity; the address is discovered unless overridden.
public struct VirtualMachineConfig: Codable, Equatable, Sendable, Identifiable {
    public static let windowsApp = "com.microsoft.rdc.macos"
    public static let firstLocalPort = 3390

    public var id: String { name }
    public var name: String
    public var guestUser: String
    public var guestAddress: String
    public var sshPort: Int
    public var rdpPort: Int
    public var localPort: Int
    /// Bundle identifier of the app that opens `.rdp` files; empty uses the system default handler.
    public var rdpClient: String
    public var display: RDPDisplay

    public init(name: String, guestUser: String = "", guestAddress: String = "", sshPort: Int = 22,
                rdpPort: Int = 3389, localPort: Int = VirtualMachineConfig.firstLocalPort, rdpClient: String = VirtualMachineConfig.windowsApp,
                display: RDPDisplay = .fullHD) {
        self.name = name; self.guestUser = guestUser; self.guestAddress = guestAddress; self.sshPort = sshPort
        self.rdpPort = rdpPort; self.localPort = localPort; self.rdpClient = rdpClient; self.display = display
    }

    enum CodingKeys: String, CodingKey { case name, guestUser, guestAddress, sshPort, rdpPort, localPort, rdpClient, display }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VirtualMachineConfig(name: try c.decode(String.self, forKey: .name))
        self = defaults
        guestUser = try c.decodeIfPresent(String.self, forKey: .guestUser) ?? defaults.guestUser
        guestAddress = try c.decodeIfPresent(String.self, forKey: .guestAddress) ?? defaults.guestAddress
        sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) ?? defaults.sshPort
        rdpPort = try c.decodeIfPresent(Int.self, forKey: .rdpPort) ?? defaults.rdpPort
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? defaults.localPort
        rdpClient = try c.decodeIfPresent(String.self, forKey: .rdpClient) ?? defaults.rdpClient
        // An unknown size (e.g. saved by a newer build) falls back to the default instead of dropping the whole config.
        display = (try? c.decodeIfPresent(RDPDisplay.self, forKey: .display)) ?? defaults.display
    }

    /// New VMs get the first local port not claimed by another saved VM, so tunnels never collide by default.
    public static func makeDefault(name: String, existing: [VirtualMachineConfig]) -> VirtualMachineConfig {
        let used = Set(existing.map(\.localPort))
        let port = (firstLocalPort...65535).first { !used.contains($0) } ?? firstLocalPort
        return VirtualMachineConfig(name: name, localPort: port)
    }

    /// Conservative subset of libvirt names; anything else is shown but never sent to a command.
    public static func isSafeName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"#, options: .regularExpression) != nil
    }
    public static func isValidHost(_ host: String) -> Bool {
        if isIPv4(host) { return true }
        return host.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,252})$"#, options: .regularExpression) != nil
    }
    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
        }
    }

    public var validationError: String? {
        if !Self.isSafeName(name) { return "nome de VM não suportado." }
        if guestUser.hasPrefix("-") || !guestUser.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }) {
            return "usuário SSH do convidado inválido."
        }
        if !guestAddress.isEmpty && !Self.isValidHost(guestAddress) { return "endereço do convidado inválido." }
        for port in [sshPort, rdpPort, localPort] where !(1...65535).contains(port) { return "porta fora do intervalo 1–65535." }
        if localPort < 1024 { return "use uma porta local a partir de 1024." }
        if rdpClient.contains(where: { $0.isWhitespace || $0 == "/" }) { return "cliente RDP inválido." }
        return nil
    }
    public var isValid: Bool { validationError == nil }

    /// The configured override wins; otherwise the address libvirt reported. Both are validated before use.
    public func endpoint(for machine: VirtualMachine?) -> String? {
        let candidate = guestAddress.isEmpty ? machine?.address : guestAddress
        guard let candidate, Self.isValidHost(candidate) else { return nil }
        return candidate
    }

    public func tunnel(to host: String) -> TunnelSpec {
        TunnelSpec(localPort: localPort, remoteHost: host, remotePort: rdpPort)
    }

    /// SSH into the guest, jumping through the homelab connection so keys and host-key checks stay local.
    public func guestArguments(address: String, via jump: Connection, interactive: Bool, command: String? = nil) -> [String] {
        var args = Connection(host: address, user: guestUser, port: sshPort).arguments(interactive: interactive, command: command)
        let separator = args.firstIndex(of: "--") ?? args.endIndex
        args.insert(contentsOf: ["-J", jump.jumpSpecification], at: separator)
        return args
    }
    public func guestDestination(address: String) -> String { guestUser.isEmpty ? address : "\(guestUser)@\(address)" }
}

extension Connection {
    var jumpSpecification: String {
        let host = self.host.contains(":") && !self.host.hasPrefix("[") ? "[\(self.host)]" : self.host
        return (user.isEmpty ? "" : "\(user)@") + host + ":\(port)"
    }
}

/// Runs `vm.py` on the server over the existing SSH connection. One SSH process per call.
public struct LibvirtClient: Sendable {
    public static let uri = "qemu:///system"
    let connection: Connection
    let execute: CommandExecutor

    public init(connection: Connection, execute: @escaping CommandExecutor = { try await ProcessRunner.run(executable: $0, arguments: $1, timeout: $2) }) {
        self.connection = connection; self.execute = execute
    }

    public static func command(_ arguments: [String]) throws -> String {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Homelab_HomelabCore.bundle")
        let resourceBundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = resourceBundle.url(forResource: "vm", withExtension: "py") else {
            throw VMError.commandFailed("O script de VMs não foi encontrado no aplicativo. Gere o app novamente.")
        }
        let script = try String(contentsOf: url, encoding: .utf8)
        return (["python3", "-c", Connection.shellQuote(script), Connection.shellQuote(uri)] + arguments.map(Connection.shellQuote)).joined(separator: " ")
    }

    static func probes(_ configs: [VirtualMachineConfig]) -> String {
        struct Probe: Encodable { let address: String; let ssh: Int; let rdp: Int }
        var probes: [String: Probe] = [:]
        for config in configs where config.isValid {
            probes[config.name] = Probe(address: config.guestAddress, ssh: config.sshPort, rdp: config.rdpPort)
        }
        let data = (try? JSONEncoder().encode(probes)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        guard let start = output.range(of: "__HL_JSON_BEGIN__\n"),
              let end = output.range(of: "\n__HL_JSON_END__", range: start.upperBound..<output.endIndex) else {
            throw VMError.commandFailed("Resposta incompleta do servidor ao consultar o libvirt.")
        }
        do { return try JSONDecoder().decode(T.self, from: Data(output[start.upperBound..<end.lowerBound].utf8)) } catch {
            throw VMError.commandFailed("Não foi possível interpretar a resposta do libvirt.")
        }
    }

    private func run(_ arguments: [String], timeout: Double) async throws -> String {
        guard connection.isValid else { throw VMError.invalidConfiguration("revise a conexão com o servidor.") }
        let result = try await execute("/usr/bin/ssh", connection.arguments(interactive: false, command: try Self.command(arguments)), timeout)
        guard result.status == 0 else {
            let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VMError.commandFailed(detail.isEmpty ? "O SSH encerrou com código \(result.status)." : String(detail.prefix(400)))
        }
        return result.output
    }

    public func inventory(_ configs: [VirtualMachineConfig]) async throws -> VMInventory {
        try Self.decode(VMInventory.self, from: try await run(["inventory", Self.probes(configs)], timeout: 25))
    }

    public func status(_ config: VirtualMachineConfig) async throws -> VirtualMachine {
        guard VirtualMachineConfig.isSafeName(config.name) else { throw VMError.invalidConfiguration("nome de VM não suportado.") }
        let inventory = try Self.decode(VMInventory.self, from: try await run(["status", config.name, Self.probes([config])], timeout: 20))
        guard inventory.available else { throw VMError.libvirtUnavailable(inventory.error ?? "sem detalhes.") }
        guard let machine = inventory.machines.first(where: { $0.name == config.name }) else { throw VMError.notFound(config.name) }
        return machine
    }

    public func start(_ name: String) async throws { try await action("start", name) }
    /// ACPI request; the guest may ignore it, so callers must confirm the state afterwards.
    public func requestShutdown(_ name: String) async throws { try await action("shutdown", name) }
    /// Equivalent to pulling the power cord. Only for explicit, confirmed user requests.
    public func forceStop(_ name: String) async throws { try await action("destroy", name) }

    private struct ActionResult: Decodable { let ok: Bool; let error: String? }
    private func action(_ verb: String, _ name: String) async throws {
        guard VirtualMachineConfig.isSafeName(name) else { throw VMError.invalidConfiguration("nome de VM não suportado.") }
        let result = try Self.decode(ActionResult.self, from: try await run([verb, name], timeout: 75))
        if !result.ok { throw VMError.commandFailed(result.error ?? "O libvirt recusou a operação.") }
    }
}

public enum GuestPowerResult: Equatable, Sendable {
    case accepted
    case authorizationRequired
    case failed(String)
}

/// Talks to the guest OS itself, through the homelab as jump host, using the Mac's keys and agent.
public struct GuestClient: Sendable {
    /// polkit first (works when a rule allows it), then sudo without prompting (works with a scoped sudoers rule).
    public static let powerOffCommand = "systemctl --no-ask-password poweroff 2>/dev/null || sudo -n systemctl poweroff"
    public static let interactivePowerOffCommand = "sudo systemctl poweroff"
    let connection: Connection
    let execute: CommandExecutor

    public init(connection: Connection, execute: @escaping CommandExecutor = { try await ProcessRunner.run(executable: $0, arguments: $1, timeout: $2) }) {
        self.connection = connection; self.execute = execute
    }

    public func powerOff(_ config: VirtualMachineConfig, address: String) async -> GuestPowerResult {
        let args = config.guestArguments(address: address, via: connection, interactive: false, command: Self.powerOffCommand)
        do {
            let result = try await execute("/usr/bin/ssh", args, 20)
            return Self.classify(result)
        } catch { return .failed(error.localizedDescription) }
    }

    static func classify(_ result: CommandResult) -> GuestPowerResult {
        if result.status == 0 { return .accepted }
        let error = result.error.lowercased()
        // The guest may drop the connection while powering off.
        if result.status == 255 && (error.contains("closed by remote host") || error.contains("connection reset")) { return .accepted }
        if error.contains("password is required") || error.contains("interactive authentication required") || error.contains("access denied") {
            return .authorizationRequired
        }
        let detail = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(detail.isEmpty ? "SSH no convidado encerrou com código \(result.status)." : String(detail.prefix(300)))
    }
}

/// `.rdp` file handed to the desktop client. Never contains credentials.
/// Clients treat an opened file as its own connection, so display settings must be spelled out here:
/// saved bookmark preferences do not apply to it.
public enum RDPFile {
    public static func contents(host: String, port: Int, username: String, display: RDPDisplay = .fullHD) -> String {
        var lines = ["full address:s:\(host):\(port)"]
        if !username.isEmpty { lines.append("username:s:\(username)") }
        // 32 bpp is required for the graphics pipeline (H.264/RFX) that xrdp prefers.
        lines += ["session bpp:i:32", "use multimon:i:0"]
        if let size = display.size {
            // Fixed remote size; a smaller window scales the image instead of resizing the session.
            lines += ["screen mode id:i:1", "desktopwidth:i:\(size.width)", "desktopheight:i:\(size.height)",
                      "dynamic resolution:i:0", "smart sizing:i:1"]
        } else {
            lines += ["screen mode id:i:2", "dynamic resolution:i:1"]
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    public static func write(name: String, port: Int, username: String, display: RDPDisplay = .fullHD, in directory: URL) throws -> URL {
        guard VirtualMachineConfig.isSafeName(name) else { throw VMError.invalidConfiguration("nome de VM não suportado.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name + ".rdp")
        try Data(contents(host: "127.0.0.1", port: port, username: username, display: display).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
