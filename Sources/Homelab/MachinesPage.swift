import SwiftUI
import HomelabCore

struct MachineStatus {
    let title: String
    let color: Color

    @MainActor init(_ machine: VirtualMachine, operation: VMOperationKind?, stopping: Bool) {
        switch (operation, machine.state) {
        case (.shutDown?, _), (.forceStop?, _), (.waitForShutdown?, _), (_, .shutdown):
            (title, color) = ("Desligando", .orange)
        case _ where stopping && !machine.isOff:
            (title, color) = ("Desligando", .orange)
        case (.start?, _) where !machine.guestReady, (.openDesktop?, _) where !machine.guestReady, (.restart?, _) where !machine.guestReady:
            (title, color) = ("Iniciando", .orange)
        case (_, .running), (_, .blocked):
            (title, color) = machine.guestReady ? ("Em execução", Theme.accent) : ("Aguardando convidado", .orange)
        case (_, .shutoff): (title, color) = ("Desligada", Theme.muted)
        case (_, .crashed): (title, color) = ("Erro", .red)
        case (_, .paused): (title, color) = ("Pausada", .orange)
        case (_, .pmsuspended): (title, color) = ("Suspensa", .orange)
        case (_, .nostate): (title, color) = ("Indisponível", Theme.muted)
        }
    }
}

struct MachinesPage: View {
    @ObservedObject var machines: MachinesModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Eyebrow(text: "Libvirt · \(LibvirtClient.uri)")
                Spacer()
                Cadence(seconds: MachinesModel.pollInterval)
            }
            if !machines.loaded {
                Panel { EmptyPanel(icon: "desktopcomputer", title: "Consultando o libvirt", detail: "As máquinas virtuais do servidor aparecerão aqui.") }
            } else if let error = machines.libvirtError {
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Libvirt indisponível", systemImage: "exclamationmark.triangle").font(.system(size: 14, weight: .semibold)).foregroundStyle(.orange)
                        Text(error).font(.system(size: 12)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        Text("O restante do painel continua funcionando. Confira se o libvirt está instalado e se o usuário SSH pertence ao grupo libvirt.")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                }
            } else if machines.machines.isEmpty {
                Panel { EmptyPanel(icon: "desktopcomputer", title: "Nenhuma máquina virtual", detail: "O libvirt não tem domínios definidos em \(LibvirtClient.uri).") }
            } else {
                ForEach(machines.machines) { machine in MachineCard(machines: machines, machine: machine) }
            }
        }
        .task { if machines.lastUpdate.map({ Date().timeIntervalSince($0) > 5 }) ?? true { await machines.refresh() } }
    }
}

private struct MachineCard: View {
    @ObservedObject var machines: MachinesModel
    let machine: VirtualMachine
    @State private var confirmingForceStop = false
    @State private var editing = false

    private var operation: VMOperationKind? { machines.running[machine.name] }
    private var config: VirtualMachineConfig { machines.config(for: machine.name) }
    private var manageable: Bool { VirtualMachineConfig.isSafeName(machine.name) }
    private var tunnel: TunnelSpec? { machines.tunnels[machine.name] }
    private var stopping: Bool { machines.stopping.contains(machine.name) }
    private var probed: Bool { machine.isRunning && !stopping }

    var body: some View {
        let status = MachineStatus(machine, operation: operation, stopping: stopping)
        Panel {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    Image(systemName: "desktopcomputer").font(.system(size: 26)).foregroundStyle(Theme.accent)
                        .frame(width: 56, height: 56).background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(machine.name).font(.system(size: 20, weight: .medium))
                        Text(config.endpoint(for: machine) ?? (machine.isRunning ? "Sem endereço de rede" : "Endereço disponível quando ligada"))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).textSelection(.enabled)
                    }
                    Spacer()
                    StatusBadge(title: status.title, color: status.color)
                }
                HStack(spacing: 25) {
                    CompactMetric(title: "vCPUs", value: machine.vcpus.map(String.init) ?? "—")
                    CompactMetric(title: "Memória", value: bytes(machine.memory))
                    CompactMetric(title: "Disco", value: bytes(machine.disk))
                }
                Divider().overlay(Theme.line)
                HStack(spacing: 18) {
                    Readiness(title: "SSH", ready: probed ? machine.sshReady : nil)
                    Readiness(title: "Desktop remoto", ready: probed ? machine.rdpReady : nil)
                    if let tunnel {
                        HStack(spacing: 6) {
                            Readiness(title: "Túnel 127.0.0.1:\(tunnel.localPort)", ready: true)
                            Button { machines.closeTunnel(machine.name) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Encerrar o túnel (a VM continua ligada)")
                        }
                    }
                    Spacer()
                }
                activity
                actions
            }
        }
        .confirmationDialog("Forçar o desligamento de \(machine.name)?", isPresented: $confirmingForceStop) {
            Button("Forçar desligamento", role: .destructive) { machines.perform(.forceStop, on: machine.name) }
        } message: {
            Text("Equivale a tirar a VM da tomada: dados não salvos no convidado podem ser perdidos. Use só se o desligamento seguro falhar.")
        }
        .sheet(isPresented: $editing) {
            MachineSettings(config: config, clients: RemoteDesktopLauncher.clients(), onSave: machines.save)
        }
    }

    @ViewBuilder private var activity: some View {
        if let stage = machines.stages[machine.name] ?? operation.map({ _ in VMStage.checking }) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(stage.title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("Cancelar") { machines.cancel(machine.name) }.buttonStyle(.borderless).font(.system(size: 12))
            }.padding(12).background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
        } else if stopping {
            Label("O convidado está encerrando. SSH e desktop param antes da VM; o estado muda para Desligada quando o libvirt confirmar.",
                  systemImage: "hourglass")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
        }
        if let failure = machines.failures[machine.name] {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                VStack(alignment: .leading, spacing: 10) {
                    Text(failure.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if failure.needsAuthorization {
                        HStack {
                            Button("Digitar senha no terminal", systemImage: "terminal") { machines.authorizeShutdown(machine.name) }
                            Button("Forçar desligamento…") { confirmingForceStop = true }.foregroundStyle(.red)
                        }.buttonStyle(.bordered)
                    } else if failure.offersForceStop {
                        Button("Forçar desligamento…") { confirmingForceStop = true }.buttonStyle(.bordered).foregroundStyle(.red)
                    }
                }
                Spacer()
                Button { machines.failures[machine.name] = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dispensar")
            }
            .font(.system(size: 12)).foregroundStyle(.orange)
            .padding(14).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { machines.perform(.openDesktop, on: machine.name) } label: {
                Label("Abrir desktop", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.background)
            .disabled(!manageable || operation != nil || machine.state == .shutdown || stopping)
            .help(machine.isRunning ? "Abre o desktop remoto pelo túnel SSH" : "Liga a VM e abre o desktop remoto quando estiver pronto")
            Button("Terminal SSH", systemImage: "terminal") { machines.openShell(machine.name) }
                .disabled(!manageable || machine.sshReady != true)
            if machine.isOff {
                Button("Ligar", systemImage: "power") { machines.perform(.start, on: machine.name) }
                    .disabled(!manageable || operation != nil)
            } else {
                Button("Desligar", systemImage: "power") { machines.perform(.shutDown, on: machine.name) }
                    .disabled(!manageable || operation != nil || !machine.isRunning || stopping)
            }
            Spacer()
            Menu {
                Button("Reiniciar", systemImage: "arrow.clockwise") { machines.perform(.restart, on: machine.name) }
                    .disabled(operation != nil || !machine.isRunning)
                Button("Atualizar estado", systemImage: "arrow.triangle.2.circlepath") { Task { await machines.refresh() } }
                Button("Configurar…", systemImage: "slider.horizontal.3") { editing = true }
                Divider()
                Button("Forçar desligamento…", systemImage: "bolt.slash", role: .destructive) { confirmingForceStop = true }
                    .disabled(machine.isOff)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().disabled(!manageable)
        }.buttonStyle(.bordered).controlSize(.regular)
    }
}

private struct Readiness: View {
    let title: String
    let ready: Bool?
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ready == true ? Theme.accent : ready == false ? Color.orange : Theme.muted).frame(width: 6, height: 6)
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            Text(ready == true ? "pronto" : ready == false ? "sem resposta" : "—").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }
}

struct MachineSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State var config: VirtualMachineConfig
    let clients: [RemoteDesktopLauncher.Client]
    let onSave: (VirtualMachineConfig) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Máquina virtual · \(config.name)").font(.title2.weight(.semibold))
            Text("O SSH no convidado passa pelo servidor (ProxyJump) com as chaves e o agente do Mac. O túnel RDP escuta apenas em 127.0.0.1.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Section("Convidado") {
                    TextField("Usuário SSH", text: $config.guestUser, prompt: Text("Opcional: padrão do SSH"))
                    TextField("Endereço", text: $config.guestAddress, prompt: Text("Automático (lease DHCP do libvirt)"))
                    TextField("Porta SSH", value: $config.sshPort, format: .number.grouping(.never))
                    TextField("Porta RDP", value: $config.rdpPort, format: .number.grouping(.never))
                }
                Section("Desktop remoto") {
                    TextField("Porta local do túnel", value: $config.localPort, format: .number.grouping(.never))
                    Picker("Cliente", selection: $config.rdpClient) {
                        ForEach(clients) { Text($0.name).tag($0.id) }
                        if !config.rdpClient.isEmpty && !clients.contains(where: { $0.id == config.rdpClient }) {
                            Text("\(RemoteDesktopLauncher.name(of: config.rdpClient)) (não instalado)").tag(config.rdpClient)
                        }
                        Text("Padrão do sistema").tag("")
                    }
                }
            }.formStyle(.grouped).frame(height: 330)
            if let error = config.validationError {
                Label(error.prefix(1).uppercased() + error.dropFirst(), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            Text("Salvar encerra o túnel atual desta VM. O app não armazena senhas.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Salvar") { onSave(config); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(!config.isValid).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 500).preferredColorScheme(.dark)
    }
}
