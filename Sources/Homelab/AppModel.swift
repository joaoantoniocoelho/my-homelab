import SwiftUI
import HomelabCore

enum Screen: String, CaseIterable, Identifiable {
    case overview = "Servidor", gpu = "GPU", ollama = "Ollama", services = "Serviços", machines = "VMs", terminal = "Terminal"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"; case .gpu: return "cpu"; case .terminal: return "terminal"
        case .ollama: return "sparkles"; case .services: return "square.stack.3d.up"
        case .machines: return "desktopcomputer"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "Seu servidor, em tempo real."
        case .gpu: return "Desempenho, memória e processos da sua GPU."
        case .terminal: return "Uma conexão direta com o seu homelab."
        case .ollama: return "Seu laboratório de inteligência artificial local."
        case .services: return "Estado dos serviços do seu servidor."
        case .machines: return "Suas máquinas virtuais do libvirt, a um clique do desktop."
        }
    }
}

struct Sample: Identifiable {
    let id = UUID()
    let date: Date
    let gpu: GPU
}

@MainActor final class AppModel: ObservableObject {
    @Published var screen: Screen = .overview
    @Published private(set) var connection: Connection
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var servicesData: Snapshot?
    @Published private(set) var systemData: Snapshot?
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var history: [Snapshot] = []
    @Published private(set) var errors: [CollectionGroup: String] = [:]
    @Published private(set) var monitoring = false
    @Published private(set) var refreshing = false
    @Published private(set) var reachable = false
    @Published var showingSettings = false
    @Published var selectedGPU: String?
    @Published var terminals: [TerminalSession] = [TerminalSession(name: "Sessão 1")]
    @Published var activeTerminal = UUID()
    let machines: MachinesModel
    private var supervisor: StreamSupervisor?
    private var consumer: Task<Void, Never>?
    private var generation = UUID()
    private var hasStarted = false
    private var windowVisible = true
    private var awake = true
    private var hideTask: Task<Void, Never>?
    /// How long the window may stay hidden before the SSH stream is closed; avoids reconnecting on brief flickers.
    var hideGrace: Double = 10
    private let probes = LockedData()

    init() {
        let saved = UserDefaults.standard.data(forKey: "connection")
        let decoded = saved.flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
        let initial = decoded?.isValid == true ? decoded! : Connection()
        connection = initial
        machines = MachinesModel(connection: initial)
        activeTerminal = terminals[0].id
        machines.onConfigsChanged = { [weak self] in
            guard let self else { return }
            probes.value = machines.probesMessage
            supervisor?.send(probes.value)
        }
        probes.value = machines.probesMessage
        machines.openTerminal = { [weak self] name, arguments, destination in
            self?.openTerminal(name: name, arguments: arguments, destination: destination)
        }
    }

    var currentGPU: GPU? { snapshot?.gpus.first(where: { $0.id == selectedGPU }) ?? snapshot?.gpus.first }
    var currentTerminal: TerminalSession { terminals.first(where: { $0.id == activeTerminal }) ?? terminals[0] }
    var status: String {
        if !monitoring { return snapshot == nil ? "Desconectado" : "Monitor pausado" }
        if errors[.fast] != nil { return reachable ? "Coleta indisponível" : "Offline" }
        if snapshot != nil { return "Online" }
        return "Conectando…"
    }
    var healthy: Bool { monitoring && errors[.fast] == nil && snapshot != nil }
    var servicesFresh: Bool { healthy && errors[.services] == nil && servicesData.map { Date().timeIntervalSince($0.timestamp) < connection.servicesInterval + 20 } == true }
    var warnings: [String] { Array(errors.values).sorted() + (snapshot?.warnings ?? []) }
    func interval(for group: CollectionGroup) -> Double {
        switch group { case .fast: return connection.interval; case .services: return connection.servicesInterval; case .system: return connection.systemInterval }
    }

    func startOnLaunch() {
        if !hasStarted { start() }
    }
    func start() {
        guard !monitoring else { return }
        hasStarted = true
        monitoring = true
        reconcile()
    }
    func pause() {
        monitoring = false
        reconcile()
    }
    /// The SSH stream runs only while the user wants monitoring, the window is visible and the Mac is awake.
    func setWindowVisible(_ visible: Bool) {
        hideTask?.cancel(); hideTask = nil
        if visible { windowVisible = true; reconcile(); return }
        hideTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(hideGrace)) } catch { return }
            windowVisible = false; reconcile()
        }
    }
    func setAwake(_ value: Bool) { awake = value; reconcile() }

    private func reconcile() {
        if monitoring && windowVisible && awake { startStreaming() } else { stopStreaming() }
    }
    func refresh() { pause(); start() }
    /// Stops sessions and tunnels only; VMs keep running until the user shuts them down explicitly.
    func disconnect() { pause(); terminals.forEach { $0.stop() }; machines.disconnect() }
    func save(_ config: Connection) {
        guard config.isValid else { return }
        disconnect(); connection = config; machines.update(connection: config); snapshot = nil; servicesData = nil; systemData = nil
        samples = []; history = []; selectedGPU = nil; errors = [:]; reachable = false
        if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "connection") }
        start()
    }
    func addTerminal() {
        let session = TerminalSession(name: "Sessão \((terminals.map(\.number).max() ?? 0) + 1)")
        terminals.append(session); activeTerminal = session.id
    }
    func openTerminal(name: String, arguments: [String], destination: String) {
        let session = TerminalSession(name: name, arguments: arguments, destination: destination)
        terminals.append(session); activeTerminal = session.id; screen = .terminal
    }
    func closeTerminal(_ session: TerminalSession) {
        session.stop(); terminals.removeAll { $0.id == session.id }
        if terminals.isEmpty { terminals.append(TerminalSession(name: "Sessão 1")) }
        if activeTerminal == session.id { activeTerminal = terminals[0].id }
    }

    private func startStreaming() {
        guard supervisor == nil else { return }
        guard connection.isValid else { errors[.fast] = "Revise os dados da conexão."; return }
        let connection = connection
        let command: String
        do { command = try Telemetry.streamCommand(connection: connection, vmInterval: MachinesModel.pollInterval) } catch {
            errors[.fast] = error.localizedDescription; return
        }
        let token = UUID(); generation = token
        let (events, continuation) = AsyncStream<StreamEvent>.makeStream(bufferingPolicy: .unbounded)
        let probes = probes
        let supervisor = StreamSupervisor(
            timing: .init(staleAfter: max(10, connection.interval * 3)),
            connect: {
                let session = ProcessStreamer(arguments: connection.streamArguments(command: command))
                try session.start()
                return session
            },
            greeting: { probes.value },
            onEvent: { continuation.yield($0) })
        self.supervisor = supervisor
        // A single consumer keeps events in order.
        consumer = Task { [weak self] in
            for await event in events {
                guard let self, generation == token else { return }
                handle(event)
            }
        }
        machines.streaming = true
        supervisor.start()
    }

    private func stopStreaming() {
        supervisor?.stop(); supervisor = nil
        consumer?.cancel(); consumer = nil
        generation = UUID(); refreshing = false
        machines.streaming = false
    }

    private func handle(_ event: StreamEvent) {
        switch event {
        case .connecting:
            refreshing = true
        case .disconnected(let message):
            refreshing = false; reachable = false
            errors[.fast] = message
            machines.receive(failure: message)
        case .message(.failure(let group, let message)):
            reachable = true
            switch group {
            case .fast: errors[.fast] = message
            case .services: errors[.services] = message
            case .system: errors[.system] = message
            case .vms: machines.receive(failure: message)
            }
        case .message(.sample(let group, let data)):
            reachable = true
            do {
                switch group {
                case .vms: machines.receive(try JSONDecoder().decode(VMInventory.self, from: data))
                case .fast: refreshing = false; try apply(Telemetry.decode(data), to: .fast)
                case .services: try apply(Telemetry.decode(data), to: .services)
                case .system: try apply(Telemetry.decode(data), to: .system)
                }
            } catch {
                switch group {
                case .fast: errors[.fast] = error.localizedDescription
                case .services: errors[.services] = error.localizedDescription
                case .system: errors[.system] = error.localizedDescription
                case .vms: machines.receive(failure: "Não foi possível interpretar a resposta do libvirt.")
                }
            }
        }
    }

    private func apply(_ latest: Snapshot, to group: CollectionGroup) {
        errors[group] = nil
        switch group {
        case .fast:
            snapshot = latest
            history.append(latest)
            history.removeAll { $0.timestamp < latest.timestamp.addingTimeInterval(-300) }
            for gpu in latest.gpus { samples.append(Sample(date: latest.timestamp, gpu: gpu)) }
            samples.removeAll { $0.date < latest.timestamp.addingTimeInterval(-300) }
        case .services: servicesData = latest
        case .system: systemData = latest
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return data }
        set { lock.lock(); data = newValue; lock.unlock() }
    }
}
