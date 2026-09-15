import SwiftUI
import HomelabCore

enum Screen: String, CaseIterable, Identifiable {
    case overview = "Servidor", gpu = "GPU", ollama = "Ollama", services = "Serviços", terminal = "Terminal"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"; case .gpu: return "cpu"; case .terminal: return "terminal"
        case .ollama: return "sparkles"; case .services: return "square.stack.3d.up"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "Seu servidor, em tempo real."
        case .gpu: return "Desempenho, memória e processos da sua GPU."
        case .terminal: return "Uma conexão direta com o seu homelab."
        case .ollama: return "Seu laboratório de inteligência artificial local."
        case .services: return "Estado dos serviços do seu servidor."
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
    private var pollTasks: [Task<Void, Never>] = []
    private var generation = UUID()
    private var hasStarted = false

    init() {
        let saved = UserDefaults.standard.data(forKey: "connection")
        let decoded = saved.flatMap { try? JSONDecoder().decode(Connection.self, from: $0) }
        connection = decoded?.isValid == true ? decoded! : Connection()
        activeTerminal = terminals[0].id
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
        let token = UUID(); generation = token
        pollTasks = CollectionGroup.allCases.map { group in
            Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let began = Date()
                    await self.fetch(group: group, token: token)
                    // Keep start-to-start cadence and never overlap requests within a group.
                    let delay = max(0.1, self.interval(for: group) - Date().timeIntervalSince(began))
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
    }
    func pause() {
        monitoring = false; generation = UUID(); pollTasks.forEach { $0.cancel() }; pollTasks = []; refreshing = false
    }
    func refresh() { pause(); start() }
    func disconnect() { pause(); terminals.forEach { $0.stop() } }
    func save(_ config: Connection) {
        guard config.isValid else { return }
        disconnect(); connection = config; snapshot = nil; servicesData = nil; systemData = nil
        samples = []; history = []; selectedGPU = nil; errors = [:]; reachable = false
        if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "connection") }
        start()
    }
    func addTerminal() {
        let session = TerminalSession(name: "Sessão \((terminals.map(\.number).max() ?? 0) + 1)")
        terminals.append(session); activeTerminal = session.id
    }
    func closeTerminal(_ session: TerminalSession) {
        session.stop(); terminals.removeAll { $0.id == session.id }
        if terminals.isEmpty { terminals.append(TerminalSession(name: "Sessão 1")) }
        if activeTerminal == session.id { activeTerminal = terminals[0].id }
    }

    private func fetch(group: CollectionGroup, token: UUID) async {
        guard connection.isValid else { errors[group] = "Revise os dados da conexão."; return }
        if group == .fast { refreshing = true }
        defer { if generation == token && group == .fast { refreshing = false } }
        do {
            let result = try await ProcessRunner.run(arguments: connection.arguments(interactive: false, command: Telemetry.command(group: group)))
            guard generation == token, !Task.isCancelled else { return }
            if group == .fast { reachable = result.status == 0 }
            guard result.status == 0 else {
                throw TelemetryError.invalid(result.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "O SSH encerrou com código \(result.status)." : String(result.error.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)))
            }
            let latest = try Telemetry.parse(result.output)
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
        } catch is CancellationError { } catch {
            guard generation == token else { return }; errors[group] = error.localizedDescription
        }
    }
}
