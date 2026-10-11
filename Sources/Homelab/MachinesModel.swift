import SwiftUI
import HomelabCore

struct VMFailure: Equatable {
    let message: String
    var needsAuthorization = false
    /// A restart that stopped at the sudo prompt resumes with a start once the guest is off.
    var restartAfterShutdown = false
    var offersForceStop = false
}

@MainActor final class MachinesModel: ObservableObject {
    static let pollInterval: Double = 15
    @Published private(set) var machines: [VirtualMachine] = []
    @Published private(set) var libvirtError: String?
    @Published private(set) var loaded = false
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var configs: [String: VirtualMachineConfig]
    @Published private(set) var stages: [String: VMStage] = [:]
    @Published private(set) var running: [String: VMOperationKind] = [:]
    @Published private(set) var tunnels: [String: TunnelSpec] = [:]
    /// VMs asked to power off that libvirt still reports as running. Guests can take minutes to stop
    /// (stop jobs) with SSH/RDP already down; that is "shutting down", not "waiting for the guest".
    @Published private(set) var stopping: Set<String> = []
    @Published var failures: [String: VMFailure] = [:]
    /// Opens an SSH tab in the app's terminal: (tab name, ssh arguments, destination label).
    var openTerminal: (String, [String], String) -> Void = { _, _, _ in }

    private var connection: Connection
    private var pollTask: Task<Void, Never>?
    private lazy var tunnelManager = TunnelManager(records: Self.records) { [weak self] in
        Task { @MainActor in self?.syncTunnels() }
    }
    private lazy var operations = makeOperations()

    private static var records: TunnelRecords {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return TunnelRecords(url: base.appendingPathComponent("Homelab/tunnels.json"))
    }

    init(connection: Connection) {
        self.connection = connection
        let saved = UserDefaults.standard.data(forKey: "virtualMachines")
        let decoded = saved.flatMap { try? JSONDecoder().decode([VirtualMachineConfig].self, from: $0) } ?? []
        configs = Dictionary(decoded.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        // Only tunnels left behind by a crashed previous run; see TunnelRecords.reapOrphans.
        Self.records.reapOrphans()
    }

    func config(for name: String) -> VirtualMachineConfig {
        configs[name] ?? VirtualMachineConfig.makeDefault(name: name, existing: Array(configs.values))
    }
    func machine(named name: String) -> VirtualMachine? { machines.first { $0.name == name } }
    var busy: Bool { !running.isEmpty }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(Self.pollInterval)) } catch { return }
            }
        }
    }
    func pause() { pollTask?.cancel(); pollTask = nil }

    /// Monitoring settings changed or the app is quitting: never leave tunnels to the old destination.
    func disconnect() {
        pause()
        tunnelManager.stopAll()
        syncTunnels()
    }
    func update(connection: Connection) {
        disconnect()
        self.connection = connection
        operations = makeOperations()
        machines = []; libvirtError = nil; loaded = false; failures = [:]; stages = [:]; running = [:]
    }

    func refresh() async {
        guard connection.isValid else { libvirtError = "Revise os dados da conexão."; loaded = true; return }
        let current = connection
        do {
            let inventory = try await LibvirtClient(connection: current).inventory(Array(configs.values))
            guard current == connection, !Task.isCancelled else { return }
            loaded = true; lastUpdate = Date()
            libvirtError = inventory.available ? nil : (inventory.error ?? "O libvirt não respondeu.")
            guard inventory.available else { machines = []; return }
            machines = inventory.machines.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            stopping = stopping.filter { name in machines.contains { $0.name == name && !$0.isOff } }
            adoptNewMachines()
            for machine in machines where machine.isOff && tunnels[machine.name] != nil { tunnelManager.stop(machine.name) }
        } catch is CancellationError { } catch {
            guard current == connection else { return }
            loaded = true; libvirtError = error.localizedDescription
        }
    }

    func save(_ config: VirtualMachineConfig) {
        guard config.isValid else { return }
        if configs[config.name] != config { tunnelManager.stop(config.name) }
        configs[config.name] = config
        persist()
        Task { await refresh() }
    }

    /// Returns whether the operation succeeded. The UI disables actions while one runs; the core also
    /// joins duplicate requests, so a double click never starts two flows.
    @discardableResult
    func perform(_ kind: VMOperationKind, on name: String) -> Task<Bool, Never> {
        guard running[name] == nil else { return Task { false } }
        let config = config(for: name)
        failures[name] = nil
        running[name] = kind
        let operations = operations
        return Task { [self] in
            var succeeded = false
            do {
                try await operations.perform(kind, config) { stage in
                    Task { @MainActor in
                        guard self.running[name] != nil else { return }
                        self.stages[name] = stage
                        if stage == .waitingForShutdown || stage == .forcingStop { self.stopping.insert(name) }
                        if stage == .starting { self.stopping.remove(name) }
                    }
                }
                succeeded = true
            } catch is CancellationError { } catch VMError.shutdownNeedsAuthorization {
                failures[name] = VMFailure(message: VMError.shutdownNeedsAuthorization.localizedDescription
                    + " Digite-a no terminal do app: ela vai direto para o sudo do convidado e não é armazenada.",
                    needsAuthorization: true, restartAfterShutdown: kind == .restart)
            } catch {
                failures[name] = VMFailure(message: error.localizedDescription, offersForceStop: error as? VMError == .shutdownTimedOut)
            }
            running[name] = nil; stages[name] = nil
            await refresh()
            return succeeded
        }
    }

    func cancel(_ name: String) { Task { await operations.cancel(name) } }
    func closeTunnel(_ name: String) { tunnelManager.stop(name) }

    func openShell(_ name: String) {
        let config = config(for: name)
        guard let address = config.endpoint(for: machine(named: name)) else {
            failures[name] = VMFailure(message: VMError.noAddress.localizedDescription); return
        }
        openTerminal(name, config.guestArguments(address: address, via: connection, interactive: true), config.guestDestination(address: address))
    }

    /// The sudo prompt runs in the app's own terminal; meanwhile the app watches libvirt for the power-off.
    func authorizeShutdown(_ name: String) {
        let config = config(for: name)
        guard let address = config.endpoint(for: machine(named: name)) else {
            failures[name] = VMFailure(message: VMError.noAddress.localizedDescription); return
        }
        let restart = failures[name]?.restartAfterShutdown == true
        failures[name] = nil
        openTerminal("\(name) · desligar", config.guestArguments(address: address, via: connection, interactive: true,
                                                                 command: GuestClient.interactivePowerOffCommand),
                     config.guestDestination(address: address))
        let wait = perform(.waitForShutdown, on: name)
        guard restart else { return }
        Task { if await wait.value { perform(.start, on: name) } }
    }

    private func makeOperations() -> VMOperations {
        var deps = VMOperations.Dependencies.live(connection: connection, tunnels: tunnelManager) { config in
            try await RemoteDesktopLauncher.launch(config)
        }
        let status = deps.status
        // Flows poll faster than the inventory; surface each observation in the UI.
        deps.status = { [weak self] config in
            let machine = try await status(config)
            await self?.apply(machine)
            return machine
        }
        return VMOperations(dependencies: deps)
    }

    private func apply(_ machine: VirtualMachine) {
        guard let index = machines.firstIndex(where: { $0.name == machine.name }) else { return }
        machines[index] = machine
        if machine.isOff { stopping.remove(machine.name) }
    }

    private func adoptNewMachines() {
        var changed = false
        for machine in machines where configs[machine.name] == nil && VirtualMachineConfig.isSafeName(machine.name) {
            configs[machine.name] = VirtualMachineConfig.makeDefault(name: machine.name, existing: Array(configs.values))
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        let list = configs.values.sorted { $0.name < $1.name }
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: "virtualMachines") }
    }

    private func syncTunnels() {
        var active: [String: TunnelSpec] = [:]
        for name in Set(configs.keys).union(machines.map(\.name)) {
            if let spec = tunnelManager.spec(for: name) { active[name] = spec }
        }
        if active != tunnels { tunnels = active }
    }
}
