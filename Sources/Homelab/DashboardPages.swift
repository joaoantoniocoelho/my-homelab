import SwiftUI
import Charts
import HomelabCore

func bytes(_ value: Double?) -> String {
    guard let value else { return "—" }
    if value < 1_073_741_824 { return metric(value / 1_048_576, suffix: " MiB", decimals: 0) }
    return metric(value / 1_073_741_824, suffix: " GiB", decimals: 1)
}
func ratio(_ used: Double?, _ total: Double?) -> Double? {
    guard let used, let total, total > 0 else { return nil }; return used / total
}
func uptime(_ seconds: Double?) -> String {
    guard let seconds else { return "—" }
    let minutes = Int(seconds) / 60
    if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
    return "\(minutes / 60)h \(minutes % 60)m"
}

struct ServerPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Eyebrow(text: "Recursos do servidor")
                Spacer()
                Cadence(seconds: model.connection.interval)
            }
            HStack(spacing: 14) {
                MetricCard(title: "CPU", value: metric(model.snapshot?.cpu, suffix: "%"), detail: "\(model.snapshot?.cores.map(String.init) ?? "—") processadores lógicos", icon: "cpu", fraction: model.snapshot?.cpu.map { $0 / 100 })
                MetricCard(title: "Memória RAM", value: bytes(model.snapshot?.memoryUsed), detail: "usados de \(bytes(model.snapshot?.memoryTotal))", icon: "memorychip", color: Theme.purple, fraction: ratio(model.snapshot?.memoryUsed, model.snapshot?.memoryTotal))
                MetricCard(title: "Disco · /", value: bytes(model.systemData?.diskUsed), detail: "usados de \(bytes(model.systemData?.diskTotal))", icon: "internaldrive", color: .cyan, fraction: ratio(model.systemData?.diskUsed, model.systemData?.diskTotal))
                MetricCard(title: "Uptime", value: uptime(model.systemData?.uptime), detail: "Desde a última inicialização", icon: "clock.arrow.circlepath", color: .orange)
            }
            HStack(alignment: .top, spacing: 18) {
                Panel {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("Atividade do servidor").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            ChartLegend(name: "CPU", color: Theme.accent)
                            ChartLegend(name: "RAM", color: Theme.purple)
                        }
                        HistoryChart(points: serverPoints, colors: [Theme.accent, Theme.purple])
                        HStack {
                            Text("LOAD AVERAGE").font(.system(size: 9, weight: .semibold)).tracking(1)
                            Spacer()
                            ForEach(Array((model.snapshot?.load ?? []).enumerated()), id: \.offset) { i, load in
                                Text("\(metric(load, decimals: 2)) / \([1, 5, 15][min(i, 2)])m").font(.system(size: 11, design: .monospaced))
                            }
                        }.foregroundStyle(Theme.muted)
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Text("Serviços").font(.system(size: 14, weight: .semibold)); Spacer(); Cadence(seconds: model.connection.servicesInterval) }
                        ServiceRows()
                        Button { model.screen = .services } label: { HStack { Text("Ver serviços"); Spacer(); Image(systemName: "arrow.up.right") } }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.accent)
                    }
                }.frame(width: 260)
            }
            HStack(alignment: .top, spacing: 18) {
                Panel {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Image(systemName: "cpu").foregroundStyle(Theme.accent)
                            Text(model.currentGPU?.name.replacingOccurrences(of: "NVIDIA GeForce ", with: "") ?? "GPU NVIDIA").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Button { model.screen = .gpu } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(Theme.muted).help("Detalhes da GPU")
                        }
                        HStack(spacing: 25) {
                            CompactMetric(title: "GPU", value: metric(model.currentGPU?.utilization, suffix: "%"))
                            CompactMetric(title: "VRAM", value: bytes(model.currentGPU?.memoryUsed.map { $0 * 1_048_576 }))
                            CompactMetric(title: "TEMP.", value: metric(model.currentGPU?.temperature, suffix: "°C"))
                            CompactMetric(title: "POTÊNCIA", value: metric(model.currentGPU?.power, suffix: " W", decimals: 1))
                        }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(Theme.purple)
                            Text("Ollama").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Button { model.screen = .ollama } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(Theme.muted).help("Detalhes do Ollama")
                        }
                        Text(model.servicesFresh ? (model.servicesData?.models.count == 1 ? "1 modelo carregado" : "\(model.servicesData?.models.count ?? 0) modelos carregados") : "Aguardando estado atualizado")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                        Text("Inferência local, no seu servidor.").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }.frame(width: 260)
            }
        }
    }
    private var serverPoints: [ChartPoint] {
        model.history.flatMap { snapshot in
            var points: [ChartPoint] = []
            if let cpu = snapshot.cpu { points.append(ChartPoint(date: snapshot.timestamp, value: cpu, series: "CPU")) }
            if let ram = ratio(snapshot.memoryUsed, snapshot.memoryTotal) { points.append(ChartPoint(date: snapshot.timestamp, value: ram * 100, series: "RAM")) }
            return points
        }
    }
}

struct GPUPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "cpu").font(.system(size: 28)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.currentGPU?.name ?? "Aguardando GPU").font(.system(size: 22, weight: .medium))
                    Text("Driver \(model.currentGPU?.driver ?? "—") · \(bytes(model.currentGPU?.memoryTotal.map { $0 * 1_048_576 })) de VRAM")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                if (model.snapshot?.gpus.count ?? 0) > 1 {
                    Picker("GPU", selection: Binding(get: { model.currentGPU?.id ?? "" }, set: { model.selectedGPU = $0 })) {
                        ForEach(model.snapshot?.gpus ?? []) { gpu in Text("GPU \(gpu.index)").tag(gpu.id) }
                    }.frame(width: 120)
                }
                Cadence(seconds: model.connection.interval)
            }
            HStack(spacing: 14) {
                MetricCard(title: "Utilização", value: metric(model.currentGPU?.utilization, suffix: "%"), detail: "Capacidade de processamento", icon: "waveform.path.ecg", fraction: model.currentGPU?.utilization.map { $0 / 100 })
                MetricCard(title: "VRAM usada", value: bytes(model.currentGPU?.memoryUsed.map { $0 * 1_048_576 }), detail: "de \(bytes(model.currentGPU?.memoryTotal.map { $0 * 1_048_576 }))", icon: "memorychip", color: Theme.purple, fraction: model.currentGPU?.memoryPercent.map { $0 / 100 })
                MetricCard(title: "Temperatura", value: metric(model.currentGPU?.temperature, suffix: "°C"), detail: "Ventoinha \(metric(model.currentGPU?.fan, suffix: "%"))", icon: "thermometer.medium", color: .orange)
                MetricCard(title: "Consumo", value: metric(model.currentGPU?.power, suffix: " W", decimals: 1), detail: "Limite de \(metric(model.currentGPU?.powerLimit, suffix: " W"))", icon: "bolt", color: .cyan, fraction: ratio(model.currentGPU?.power, model.currentGPU?.powerLimit))
            }
            Panel {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Atividade da GPU").font(.system(size: 14, weight: .semibold)); Spacer()
                        ChartLegend(name: "GPU", color: Theme.accent); ChartLegend(name: "VRAM", color: Theme.purple)
                    }
                    HistoryChart(points: gpuPoints, colors: [Theme.accent, Theme.purple])
                    HStack(spacing: 24) {
                        Label("Clock GPU  \(metric(model.currentGPU?.gpuClock, suffix: " MHz"))", systemImage: "speedometer")
                        Label("Clock memória  \(metric(model.currentGPU?.memoryClock, suffix: " MHz"))", systemImage: "memorychip")
                    }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            Panel { ProcessList(processes: model.snapshot?.processes.filter { $0.gpuUUID == model.currentGPU?.uuid } ?? [], available: model.snapshot != nil && model.currentGPU != nil && !(model.snapshot?.warnings.contains { $0.localizedCaseInsensitiveContains("processo") } ?? false)) }
        }
    }
    private var gpuPoints: [ChartPoint] {
        model.samples.filter { $0.gpu.id == model.currentGPU?.id }.flatMap { sample in
            var result: [ChartPoint] = []
            if let value = sample.gpu.utilization { result.append(ChartPoint(date: sample.date, value: value, series: "GPU")) }
            if let value = sample.gpu.memoryPercent { result.append(ChartPoint(date: sample.date, value: value, series: "VRAM")) }
            return result
        }
    }
}

struct ProcessList: View {
    let processes: [GPUProcess]
    let available: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Processos de computação").font(.system(size: 14, weight: .semibold)); Spacer(); Text("\(processes.count) processos").font(.system(size: 11)).foregroundStyle(Theme.muted) }
            if processes.isEmpty {
                EmptyPanel(icon: "tray", title: available ? "GPU livre para o próximo trabalho" : "Processos indisponíveis", detail: available ? "Nenhum processo CUDA em execução nesta GPU." : "Aguardando uma coleta válida da GPU.")
            } else {
                HStack { Eyebrow(text: "PID").frame(width: 75, alignment: .leading); Eyebrow(text: "Processo"); Spacer(); Eyebrow(text: "VRAM") }
                ForEach(processes.sorted { ($0.memory ?? 0) > ($1.memory ?? 0) }) { process in
                    Divider().overlay(Theme.line)
                    HStack {
                        Text(String(process.pid)).foregroundStyle(Theme.secondary).frame(width: 75, alignment: .leading)
                        Text(process.name).lineLimit(1).truncationMode(.middle).help(process.name)
                        Spacer()
                        Text(bytes(process.memory.map { $0 * 1_048_576 })).foregroundStyle(Theme.purple)
                    }.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
    }
}

struct OllamaPage: View {
    @EnvironmentObject var model: AppModel
    private var online: Bool { model.servicesFresh && model.servicesData?.services.first(where: { $0.name == "Ollama" })?.online == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Panel {
                HStack(spacing: 20) {
                    Image(systemName: "sparkles").font(.system(size: 36)).foregroundStyle(Theme.purple)
                        .frame(width: 76, height: 76).background(Theme.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Inteligência local.").font(.system(size: 25, weight: .medium))
                        Text("Modelos carregados na memória do seu homelab.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    StatusBadge(title: model.servicesFresh ? (online ? "Online" : "Offline") : "Sem dados atuais", color: online ? Theme.accent : .orange)
                }
            }
            HStack(spacing: 14) {
                MetricCard(title: "Modelos carregados", value: model.servicesFresh ? String(model.servicesData?.models.count ?? 0) : "—", detail: "Prontos para inferência", icon: "square.stack.3d.up", color: Theme.purple)
                MetricCard(title: "VRAM dos modelos", value: model.servicesFresh ? bytes(model.servicesData?.models.reduce(0) { $0 + ($1.sizeVRAM ?? 0) }) : "—", detail: "Memória reportada pelo Ollama", icon: "memorychip", color: Theme.accent)
            }
            Panel {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text("Modelos em execução").font(.system(size: 15, weight: .semibold)); Spacer(); Cadence(seconds: model.connection.servicesInterval) }
                    if model.servicesData?.models.isEmpty != false {
                        EmptyPanel(icon: "sparkles", title: online ? "Pronto para começar" : "Aguardando o Ollama", detail: online ? "O Ollama está online, mas nenhum modelo está carregado na memória." : "Os modelos aparecerão aqui quando a API do Ollama estiver disponível.")
                    } else {
                        ForEach(model.servicesData?.models ?? []) { loaded in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack { Image(systemName: "cube").foregroundStyle(Theme.purple); Text(loaded.name).font(.system(size: 15, weight: .medium)); Spacer(); Text(bytes(loaded.sizeVRAM) + " VRAM").foregroundStyle(Theme.accent) }
                                HStack(spacing: 24) {
                                    Text(loaded.parameterSize ?? "Parâmetros —")
                                    Text(loaded.quantization ?? "Quantização —")
                                    Text("Tamanho \(bytes(loaded.size))")
                                }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            }.padding(18).background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
    }
}

struct ServicesPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Eyebrow(text: "Infraestrutura"); Spacer(); Cadence(seconds: model.connection.servicesInterval) }
            Panel { ServiceRows(expanded: true) }
            Panel {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Frequência de atualização").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 45) {
                        CompactMetric(title: "CPU / RAM / GPU", value: "\(Int(model.connection.interval))s")
                        CompactMetric(title: "DOCKER / OLLAMA", value: "\(Int(model.connection.servicesInterval))s")
                        CompactMetric(title: "DISCO / UPTIME", value: "\(Int(model.connection.systemInterval))s")
                    }
                    Button("Ajustar intervalos") { model.showingSettings = true }.buttonStyle(.borderless).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

struct ServiceRows: View {
    @EnvironmentObject var model: AppModel
    var expanded = false
    var body: some View {
        VStack(spacing: expanded ? 22 : 18) {
            ForEach(["SSH", "Docker", "Ollama"], id: \.self) { name in
                let service = model.servicesData?.services.first { $0.name == name }
                let fresh = name == "SSH" ? model.healthy : model.servicesFresh
                let online = fresh && (name == "SSH" || service?.online == true)
                HStack(spacing: 12) {
                    Image(systemName: name == "SSH" ? "terminal" : name == "Docker" ? "shippingbox" : "sparkles")
                        .font(.system(size: expanded ? 21 : 15)).foregroundStyle(Theme.secondary).frame(width: expanded ? 40 : 20)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name).font(.system(size: expanded ? 16 : 12, weight: .medium))
                        if expanded {
                            Text(fresh ? (service?.detail ?? "Conexão autenticada") : "Aguardando uma verificação atualizada")
                                .font(.system(size: 12))
                                .foregroundStyle(fresh && (service?.unhealthyCount ?? 0) > 0 ? Color.orange : Theme.muted)
                        }
                    }
                    Spacer()
                    StatusBadge(title: !fresh ? "—" : online ? "Online" : service?.state == "unknown" ? "Indisponível" : "Offline", color: online ? Theme.accent : Theme.muted)
                }
                if expanded && name != "Ollama" { Divider().overlay(Theme.line) }
            }
        }
    }
}

struct ChartPoint: Identifiable {
    var id: String { "\(date.timeIntervalSince1970)-\(series)" }
    let date: Date
    let value: Double
    let series: String
}

struct HistoryChart: View {
    let points: [ChartPoint]
    let colors: [Color]
    var body: some View {
        Group {
            if points.isEmpty {
                EmptyPanel(icon: "waveform.path.ecg", title: "Aguardando métricas", detail: "O histórico será construído durante esta sessão.")
            } else {
                Chart(points) { point in
                    LineMark(x: .value("Horário", point.date), y: .value("Uso", point.value))
                        .foregroundStyle(by: .value("Recurso", point.series)).lineStyle(StrokeStyle(lineWidth: 2))
                    if points.count <= 2 {
                        PointMark(x: .value("Horário", point.date), y: .value("Uso", point.value)).foregroundStyle(by: .value("Recurso", point.series))
                    }
                }
                .chartForegroundStyleScale(range: colors).chartLegend(.hidden)
                .chartYScale(domain: 0...100)
                .chartXScale(domain: chartDomain)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 9)).foregroundStyle(Theme.muted) }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute().second()).font(.system(size: 9)).foregroundStyle(Theme.muted) } }
            }
        }.frame(height: 165)
        .accessibilityLabel("Histórico de uso dos últimos cinco minutos")
    }
    private var chartDomain: ClosedRange<Date> {
        let last = points.map(\.date).max() ?? Date()
        let first = points.map(\.date).min() ?? last
        return min(first, last.addingTimeInterval(-30))...last.addingTimeInterval(1)
    }
}

struct ChartLegend: View {
    let name: String
    let color: Color
    var body: some View { HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(name).font(.system(size: 10)).foregroundStyle(Theme.secondary) } }
}
struct CompactMetric: View {
    let title: String
    let value: String
    var body: some View { VStack(alignment: .leading, spacing: 8) { Eyebrow(text: title); Text(value).font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit() }.frame(maxWidth: .infinity, alignment: .leading) }
}
struct Cadence: View {
    let seconds: Double
    var body: some View { Label("A cada \(Int(seconds))s", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 10)).foregroundStyle(Theme.muted) }
}
struct EmptyPanel: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 23)).foregroundStyle(Theme.muted)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 25)
    }
}
