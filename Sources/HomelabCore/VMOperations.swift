import Foundation

public enum VMStage: Equatable, Sendable {
    case checking, starting, waitingForGuest, openingTunnel, verifyingDesktop, launchingClient
    case requestingShutdown, waitingForShutdown, forcingStop

    public var title: String {
        switch self {
        case .checking: return "Verificando a VM…"
        case .starting: return "Ligando a VM…"
        case .waitingForGuest: return "Aguardando o sistema convidado…"
        case .openingTunnel: return "Abrindo túnel SSH…"
        case .verifyingDesktop: return "Verificando o desktop remoto…"
        case .launchingClient: return "Abrindo o cliente de desktop remoto…"
        case .requestingShutdown: return "Pedindo desligamento ao convidado…"
        case .waitingForShutdown: return "Aguardando a VM desligar · o convidado pode levar alguns minutos…"
        case .forcingStop: return "Forçando o desligamento…"
        }
    }
}

public enum VMOperationKind: String, Sendable {
    case openDesktop, start, shutDown, restart, forceStop, waitForShutdown
}

/// Lifecycle and one-click desktop flows. At most one operation runs per VM; repeating the same
/// request joins the running one instead of starting a second flow (no duplicate tunnels or starts).
public actor VMOperations {
    public struct Dependencies: Sendable {
        public var status: @Sendable (VirtualMachineConfig) async throws -> VirtualMachine
        public var start: @Sendable (String) async throws -> Void
        public var requestShutdown: @Sendable (String) async throws -> Void
        public var forceStop: @Sendable (String) async throws -> Void
        public var guestPowerOff: @Sendable (VirtualMachineConfig, String) async -> GuestPowerResult
        public var openTunnel: @Sendable (VirtualMachineConfig, TunnelSpec) async throws -> Void
        public var closeTunnel: @Sendable (String) -> Void
        public var probeDesktop: @Sendable (Int) async -> Bool
        public var launchClient: @Sendable (VirtualMachineConfig) async throws -> Void
        public var sleep: @Sendable (Duration) async throws -> Void

        public init(status: @escaping @Sendable (VirtualMachineConfig) async throws -> VirtualMachine,
                    start: @escaping @Sendable (String) async throws -> Void,
                    requestShutdown: @escaping @Sendable (String) async throws -> Void,
                    forceStop: @escaping @Sendable (String) async throws -> Void,
                    guestPowerOff: @escaping @Sendable (VirtualMachineConfig, String) async -> GuestPowerResult,
                    openTunnel: @escaping @Sendable (VirtualMachineConfig, TunnelSpec) async throws -> Void,
                    closeTunnel: @escaping @Sendable (String) -> Void,
                    probeDesktop: @escaping @Sendable (Int) async -> Bool,
                    launchClient: @escaping @Sendable (VirtualMachineConfig) async throws -> Void,
                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
            self.status = status; self.start = start; self.requestShutdown = requestShutdown; self.forceStop = forceStop
            self.guestPowerOff = guestPowerOff; self.openTunnel = openTunnel; self.closeTunnel = closeTunnel
            self.probeDesktop = probeDesktop; self.launchClient = launchClient; self.sleep = sleep
        }

        public static func live(connection: Connection, tunnels: TunnelManager,
                                launchClient: @escaping @Sendable (VirtualMachineConfig) async throws -> Void) -> Dependencies {
            let libvirt = LibvirtClient(connection: connection)
            let guest = GuestClient(connection: connection)
            return Dependencies(
                status: { try await libvirt.status($0) },
                start: { try await libvirt.start($0) },
                requestShutdown: { try await libvirt.requestShutdown($0) },
                forceStop: { try await libvirt.forceStop($0) },
                guestPowerOff: { await guest.powerOff($0, address: $1) },
                openTunnel: { try await tunnels.ensure($0.name, spec: $1, connection: connection) },
                closeTunnel: { tunnels.stop($0) },
                probeDesktop: { await NetworkProbe.rdpResponds($0) },
                launchClient: launchClient)
        }
    }

    public struct Timing: Sendable {
        public var poll: Duration
        public var boot: Duration
        public var shutdown: Duration
        /// Longer: the user is typing the sudo password in the terminal.
        public var authorizedShutdown: Duration
        public init(poll: Duration = .seconds(2), boot: Duration = .seconds(180), shutdown: Duration = .seconds(120),
                    authorizedShutdown: Duration = .seconds(300)) {
            self.poll = poll; self.boot = boot; self.shutdown = shutdown; self.authorizedShutdown = authorizedShutdown
        }
    }

    private struct Running { let kind: VMOperationKind; let id: UUID; let task: Task<Void, Error> }
    private var running: [String: Running] = [:]
    private let deps: Dependencies
    private let timing: Timing

    public init(dependencies: Dependencies, timing: Timing = Timing()) {
        self.deps = dependencies; self.timing = timing
    }

    public func perform(_ kind: VMOperationKind, _ config: VirtualMachineConfig,
                        progress: @escaping @Sendable (VMStage) -> Void = { _ in }) async throws {
        if let error = config.validationError { throw VMError.invalidConfiguration(error) }
        if let current = running[config.name] {
            guard current.kind == kind else { throw VMError.busy(config.name) }
            try await current.task.value
            return
        }
        let id = UUID()
        let task = Task { try await self.execute(kind, config, progress) }
        running[config.name] = Running(kind: kind, id: id, task: task)
        defer { if running[config.name]?.id == id { running[config.name] = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func cancel(_ name: String) { running[name]?.task.cancel() }

    private func execute(_ kind: VMOperationKind, _ config: VirtualMachineConfig, _ progress: @escaping @Sendable (VMStage) -> Void) async throws {
        switch kind {
        case .openDesktop: try await openDesktop(config, progress)
        case .start: try await start(config, progress)
        case .shutDown: try await shutDown(config, progress)
        case .restart:
            try await shutDown(config, progress)
            try await start(config, progress)
        case .forceStop:
            progress(.forcingStop)
            try await deps.forceStop(config.name)
            try await waitUntilOff(config, timeout: timing.shutdown, progress)
        case .waitForShutdown: try await waitUntilOff(config, timeout: timing.authorizedShutdown, progress)
        }
    }

    private func powerOn(_ config: VirtualMachineConfig, _ progress: @escaping @Sendable (VMStage) -> Void) async throws -> VirtualMachine {
        progress(.checking)
        let machine = try await deps.status(config)
        switch machine.state {
        case .running, .blocked: return machine
        case .shutoff, .crashed:
            progress(.starting)
            try await deps.start(config.name)
            return try await deps.status(config)
        case .shutdown: throw VMError.stillShuttingDown
        case .paused, .pmsuspended: throw VMError.paused
        case .nostate: throw VMError.commandFailed("O libvirt informou um estado desconhecido para \(config.name).")
        }
    }

    /// Starting only waits for the guest when it can be observed; a timeout is not an error here.
    private func start(_ config: VirtualMachineConfig, _ progress: @escaping @Sendable (VMStage) -> Void) async throws {
        var machine = try await powerOn(config, progress)
        progress(.waitingForGuest)
        var attempt = 0
        while !machine.guestReady && attempt < attempts(timing.boot) {
            attempt += 1
            try await deps.sleep(timing.poll)
            machine = try await deps.status(config)
            if machine.isOff { throw VMError.commandFailed("A VM desligou durante a inicialização.") }
        }
    }

    private func openDesktop(_ config: VirtualMachineConfig, _ progress: @escaping @Sendable (VMStage) -> Void) async throws {
        var machine = try await powerOn(config, progress)
        progress(.waitingForGuest)
        var attempt = 0
        while machine.rdpReady != true {
            if machine.isOff { throw VMError.commandFailed("A VM desligou durante a inicialização.") }
            guard attempt < attempts(timing.boot) else {
                if config.endpoint(for: machine) == nil { throw VMError.noAddress }
                throw VMError.guestTimeout(sshReady: machine.sshReady == true)
            }
            attempt += 1
            try await deps.sleep(timing.poll)
            machine = try await deps.status(config)
        }
        guard let host = config.endpoint(for: machine) else { throw VMError.noAddress }
        progress(.openingTunnel)
        try await deps.openTunnel(config, config.tunnel(to: host))
        progress(.verifyingDesktop)
        var verified = false
        for attempt in 0..<3 {
            if attempt > 0 { try await deps.sleep(.seconds(1)) }
            if await deps.probeDesktop(config.localPort) { verified = true; break }
        }
        guard verified else {
            deps.closeTunnel(config.name)
            throw VMError.rdpUnreachable
        }
        try Task.checkCancellation()
        progress(.launchingClient)
        try await deps.launchClient(config)
    }

    private func shutDown(_ config: VirtualMachineConfig, _ progress: @escaping @Sendable (VMStage) -> Void) async throws {
        progress(.checking)
        let machine = try await deps.status(config)
        if machine.isOff { deps.closeTunnel(config.name); return }
        if machine.state == .paused || machine.state == .pmsuspended { throw VMError.paused }
        if machine.state != .shutdown {
            progress(.requestingShutdown)
            // The guest OS is the reliable path here; ACPI is a fallback because some guests ignore it.
            if let host = config.endpoint(for: machine), machine.sshReady == true {
                switch await deps.guestPowerOff(config, host) {
                case .accepted: break
                case .authorizationRequired: throw VMError.shutdownNeedsAuthorization
                case .failed: try await deps.requestShutdown(config.name)
                }
            } else {
                try await deps.requestShutdown(config.name)
            }
        }
        try await waitUntilOff(config, timeout: timing.shutdown, progress)
    }

    private func waitUntilOff(_ config: VirtualMachineConfig, timeout: Duration, _ progress: @escaping @Sendable (VMStage) -> Void) async throws {
        progress(.waitingForShutdown)
        for _ in 0...attempts(timeout) {
            if try await deps.status(config).isOff {
                deps.closeTunnel(config.name)
                return
            }
            try await deps.sleep(timing.poll)
        }
        throw VMError.shutdownTimedOut
    }

    private func attempts(_ timeout: Duration) -> Int { max(1, Int(timeout / timing.poll)) }
}
