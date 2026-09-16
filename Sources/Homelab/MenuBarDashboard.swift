import SwiftUI
import HomelabCore

struct HomelabMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 8) {
                if let alert = menuAlert {
                    Button { show(alert.screen) } label: {
                        Label(alert.message, systemImage: alert.icon)
                            .font(.system(size: 11)).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).help("Abrir no painel")
                }
                resources
                if let gpus = model.snapshot?.gpus, !gpus.isEmpty {
                    ForEach(gpus) { gpu in gpuCard(gpu) }
                } else {
                    Label("GPU · aguardando dados", systemImage: "cpu")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                }
                statusStrip
            }.padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 380)
        .background(Theme.background).foregroundStyle(.white).preferredColorScheme(.dark)
        .task { model.startOnLaunch() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 21)).foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36).background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.snapshot?.hostname ?? "homelab").font(.system(size: 16, weight: .semibold))
                Text(model.connection.host).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Spacer()
            StatusBadge(title: model.status, color: model.healthy ? Theme.accent : .orange)
        }.padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var resources: some View {
        HStack(alignment: .top, spacing: 16) {
            MenuMetric(title: "CPU", value: metric(model.snapshot?.cpu, suffix: "%"),
                       detail: nil, color: Theme.accent,
                       fraction: model.snapshot?.cpu.map { $0 / 100 })
            MenuMetric(title: "RAM", value: bytes(model.snapshot?.memoryUsed),
                       detail: "usados de \(bytes(model.snapshot?.memoryTotal))", color: Theme.purple,
                       fraction: ratio(model.snapshot?.memoryUsed, model.snapshot?.memoryTotal))
        }.padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
    }

    private func gpuCard(_ gpu: GPU) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(gpu.name.replacingOccurrences(of: "NVIDIA GeForce ", with: ""), systemImage: "cpu")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Label(metric(gpu.temperature, suffix: "°C"), systemImage: "thermometer.medium")
                    .font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                MenuMetric(title: "GPU", value: metric(gpu.utilization, suffix: "%"), detail: nil,
                           color: Theme.accent, fraction: gpu.utilization.map { $0 / 100 })
                MenuMetric(title: "VRAM", value: bytes(gpu.memoryUsed.map { $0 * 1_048_576 }),
                           detail: "usados de \(bytes(gpu.memoryTotal.map { $0 * 1_048_576 }))",
                           color: Theme.purple, fraction: gpu.memoryPercent.map { $0 / 100 })
            }
        }.padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
    }

    private var statusStrip: some View {
        VStack(spacing: 8) {
            statusRow(title: "SSH", icon: "terminal", trailing: sshTrailing)
            statusRow(title: "Docker", icon: "shippingbox", trailing: dockerTrailing)
            statusRow(title: "Ollama", icon: "sparkles", trailing: ollamaTrailing, accent: Theme.purple)
        }.padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
    }

    private func statusRow(title: String, icon: String, trailing: StatusBadge, accent: Color? = nil) -> some View {
        HStack {
            Label(title, systemImage: icon).font(.system(size: 11))
                .foregroundStyle(accent ?? Color.primary)
            Spacer()
            trailing
        }
    }

    private var dockerService: Service? { model.servicesData?.services.first { $0.name == "Docker" } }
    private var ollamaService: Service? { model.servicesData?.services.first { $0.name == "Ollama" } }

    private var sshTrailing: StatusBadge {
        StatusBadge(title: model.healthy ? "Online" : "Sem dados atuais",
                    color: model.healthy ? Theme.accent : Theme.muted)
    }

    private var dockerTrailing: StatusBadge {
        let service = dockerService
        let fresh = model.servicesFresh && service != nil
        guard fresh, let service else {
            return StatusBadge(title: "—", color: Theme.muted)
        }
        if !service.online {
            return StatusBadge(title: service.state == "unknown" ? "Indisponível" : "Offline", color: Theme.muted)
        }
        if let running = service.runningCount {
            let unhealthy = (service.unhealthyCount ?? 0) > 0
            return StatusBadge(title: "\(running) running", color: unhealthy ? .orange : Theme.accent)
        }
        return StatusBadge(title: "Online", color: Theme.accent)
    }

    private var ollamaTrailing: StatusBadge {
        let service = ollamaService
        let fresh = model.servicesFresh && service != nil
        guard fresh, let service else {
            return StatusBadge(title: "—", color: Theme.muted)
        }
        if !service.online {
            return StatusBadge(title: service.state == "unknown" ? "Indisponível" : "Offline", color: Theme.muted)
        }
        let models = model.servicesData?.models ?? []
        if models.isEmpty {
            return StatusBadge(title: "Idle", color: Theme.accent)
        }
        let name = models[0].name
        let short = name.count > 22 ? String(name.prefix(19)) + "…" : name
        let title = models.count == 1 ? short : "\(short) +\(models.count - 1)"
        return StatusBadge(title: title, color: Theme.purple)
    }

    private var menuAlert: (message: String, icon: String, screen: Screen)? {
        if !model.monitoring {
            return ("Pausado · exibindo a última coleta", "pause.circle", .overview)
        }
        if model.errors[.fast] != nil {
            return ("Falha de coleta · ver detalhes no painel", "exclamationmark.triangle", .overview)
        }
        if model.errors[.services] != nil {
            return ("Serviços indisponíveis · ver detalhes", "exclamationmark.triangle", .services)
        }
        if let docker = dockerService, model.servicesFresh, (docker.unhealthyCount ?? 0) > 0 {
            return ("Docker com containers unhealthy", "exclamationmark.triangle", .services)
        }
        if !model.warnings.isEmpty {
            let gpuRelated = model.warnings.contains { $0.localizedCaseInsensitiveContains("gpu") || $0.localizedCaseInsensitiveContains("nvidia") }
            return ("Alguns dados estão indisponíveis · ver detalhes", "exclamationmark.triangle", gpuRelated ? .gpu : .overview)
        }
        return nil
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let date = model.snapshot?.timestamp {
                        Text("Coleta \(date, style: .relative) atrás")
                    } else { Text("Aguardando primeira coleta") }
                }.font(.system(size: 10)).foregroundStyle(Theme.muted)
                Spacer()
                Button { model.monitoring ? model.pause() : model.start() } label: { Image(systemName: model.monitoring ? "pause.fill" : "play.fill") }
                    .help(model.monitoring ? "Pausar monitoramento" : "Retomar monitoramento")
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.refreshing).help("Atualizar todos os dados")
            }.buttonStyle(.borderless)
            HStack(spacing: 8) {
                Button { show(.overview) } label: {
                    Label("Abrir painel", systemImage: "macwindow")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.background)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                Button { show(.terminal) } label: { Image(systemName: "terminal") }.help("Abrir terminal SSH")
                Spacer()
                Button { show(nil); model.showingSettings = true } label: { Image(systemName: "gearshape") }.help("Configurações")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Sair do Homelab")
            }.buttonStyle(.borderless).font(.system(size: 12))
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func show(_ screen: Screen?) {
        if let screen { model.screen = screen }
        dismiss()
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuMetric: View {
    let title: String
    let value: String
    let detail: String?
    let color: Color
    let fraction: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
            GeometryReader { geometry in
                Capsule().fill(color.opacity(0.1))
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction ?? 0)))
            }.frame(height: 3).padding(.vertical, 1)
            if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
