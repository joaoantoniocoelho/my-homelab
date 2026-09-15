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
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.monitoring || !model.warnings.isEmpty {
                        Button { show(.overview) } label: {
                            Label(!model.monitoring ? "Pausado · exibindo a última coleta" : "Alguns dados estão indisponíveis · ver detalhes",
                                  systemImage: !model.monitoring ? "pause.circle" : "exclamationmark.triangle")
                                .font(.system(size: 11)).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    resources
                    ForEach(model.snapshot?.gpus ?? []) { gpu in gpuCard(gpu) }
                    if model.snapshot?.gpus.isEmpty != false {
                        Button { show(.gpu) } label: {
                            Label("GPU · aguardando dados", systemImage: "cpu")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                    ollama
                    services
                }.padding(16)
            }
            // MenuBarExtra sizes its window from the content's ideal size. A
            // ScrollView with only maxHeight has zero ideal height and collapses.
            .frame(height: min(480, max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 200)))
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
            VStack(alignment: .leading, spacing: 4) {
                Text(model.snapshot?.hostname ?? "homelab").font(.system(size: 16, weight: .semibold))
                Text(model.connection.host).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Spacer()
            StatusBadge(title: model.status, color: model.healthy ? Theme.accent : .orange)
        }.padding(16)
    }

    private var resources: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                MenuMetric(title: "CPU", value: metric(model.snapshot?.cpu, suffix: "%"),
                           detail: "\(model.snapshot?.cores.map(String.init) ?? "—") threads", color: Theme.accent,
                           fraction: model.snapshot?.cpu.map { $0 / 100 })
                MenuMetric(title: "RAM", value: bytes(model.snapshot?.memoryUsed),
                           detail: "usados de \(bytes(model.snapshot?.memoryTotal))", color: Theme.purple,
                           fraction: ratio(model.snapshot?.memoryUsed, model.snapshot?.memoryTotal))
            }
            Divider().overlay(Theme.line)
            HStack {
                Label(uptime(model.systemData?.uptime), systemImage: "clock")
                Spacer()
                Label("\(bytes(model.systemData?.diskUsed)) / \(bytes(model.systemData?.diskTotal))", systemImage: "internaldrive")
            }.font(.system(size: 10)).foregroundStyle(Theme.secondary)
                .help("Uptime e espaço usado/total no disco raiz")
            HStack(spacing: 6) {
                Text("Load")
                Spacer()
                Text((model.snapshot?.load ?? []).map { metric($0, decimals: 2) }.joined(separator: "  /  "))
                    .monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(Theme.muted).help("Load average: 1, 5 e 15 minutos")
        }.padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
    }

    private func gpuCard(_ gpu: GPU) -> some View {
        Button { model.selectedGPU = gpu.id; show(.gpu) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(gpu.name.replacingOccurrences(of: "NVIDIA GeForce ", with: ""), systemImage: "cpu")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                HStack(alignment: .top, spacing: 16) {
                    MenuMetric(title: "GPU", value: metric(gpu.utilization, suffix: "%"), detail: nil,
                               color: Theme.accent, fraction: gpu.utilization.map { $0 / 100 })
                    MenuMetric(title: "VRAM", value: bytes(gpu.memoryUsed.map { $0 * 1_048_576 }),
                               detail: "usados de \(bytes(gpu.memoryTotal.map { $0 * 1_048_576 }))",
                               color: Theme.purple, fraction: gpu.memoryPercent.map { $0 / 100 })
                }
                HStack(spacing: 15) {
                    Label(metric(gpu.temperature, suffix: "°C"), systemImage: "thermometer.medium")
                    Label(metric(gpu.power, suffix: " W", decimals: 1), systemImage: "bolt")
                    Spacer()
                    let count = model.snapshot?.processes.filter { $0.gpuUUID == gpu.id }.count ?? 0
                    Text("\(count) \(count == 1 ? "processo" : "processos")")
                }.font(.system(size: 10)).foregroundStyle(Theme.secondary)
            }.padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).help("Abrir detalhes da GPU")
    }

    private var ollama: some View {
        let service = model.servicesData?.services.first { $0.name == "Ollama" }
        return Button { show(.ollama) } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label("Ollama", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.purple)
                    Spacer()
                    serviceBadge(service)
                }
                if !model.servicesFresh {
                    Text("Aguardando dados atuais").foregroundStyle(Theme.muted)
                } else if service?.online != true {
                    Text("API indisponível").foregroundStyle(Theme.muted)
                } else if model.servicesData?.models.isEmpty != false {
                    Text("Nenhum modelo na memória").foregroundStyle(Theme.secondary)
                } else {
                    ForEach(model.servicesData?.models ?? []) { loaded in
                        HStack {
                            Text(loaded.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(bytes(loaded.sizeVRAM) + " VRAM").foregroundStyle(Theme.muted)
                        }
                    }
                }
            }.font(.system(size: 11)).padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).help("Abrir modelos do Ollama")
    }

    private var services: some View {
        Button { show(.services) } label: {
            VStack(spacing: 10) {
                HStack {
                    Label("SSH", systemImage: "terminal").font(.system(size: 11))
                    Spacer()
                    StatusBadge(title: model.healthy ? "Online" : "Sem dados atuais", color: model.healthy ? Theme.accent : Theme.muted)
                }
                HStack {
                    Label("Docker", systemImage: "shippingbox").font(.system(size: 11))
                    Spacer()
                    serviceBadge(model.servicesData?.services.first { $0.name == "Docker" })
                }
                if model.servicesFresh, let docker = model.servicesData?.services.first(where: { $0.name == "Docker" }) {
                    Text(docker.detail).font(.system(size: 10))
                        .foregroundStyle((docker.unhealthyCount ?? 0) > 0 ? Color.orange : Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(14).background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).help("Abrir serviços")
    }

    private func serviceBadge(_ service: Service?) -> some View {
        let fresh = model.servicesFresh && service != nil
        let online = fresh && service?.online == true
        return StatusBadge(title: !fresh ? "—" : online ? "Online" : service?.state == "unknown" ? "Indisponível" : "Offline",
                           color: online ? Theme.accent : Theme.muted)
    }

    private var footer: some View {
        VStack(spacing: 12) {
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
            HStack(spacing: 10) {
                Button { show(.overview) } label: {
                    Label("Abrir painel", systemImage: "macwindow")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.background)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
                Button { show(.terminal) } label: { Image(systemName: "terminal") }.help("Abrir terminal SSH")
                Spacer()
                Button { show(nil); model.showingSettings = true } label: { Image(systemName: "gearshape") }.help("Configurações")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Sair do Homelab")
            }.buttonStyle(.borderless).font(.system(size: 12))
        }.padding(16)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
            GeometryReader { geometry in
                Capsule().fill(color.opacity(0.1))
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, fraction ?? 0)))
            }.frame(height: 3).padding(.vertical, 2)
            if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
