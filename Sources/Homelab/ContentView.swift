import SwiftUI
import HomelabCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 214)
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.line).frame(height: 1)
                if model.screen == .terminal {
                    terminalPage.padding(24)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            notices
                            switch model.screen {
                            case .overview: ServerPage()
                            case .gpu: GPUPage()
                            case .ollama: OllamaPage()
                            case .services: ServicesPage()
                            case .terminal: EmptyView()
                            }
                        }.padding(28).frame(maxWidth: 1500)
                            .frame(maxWidth: .infinity)
                    }
                }
                footer
            }
        }
        .background(Theme.background).foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1080, minHeight: 740)
        .sheet(isPresented: $model.showingSettings) { ConnectionSettings(connection: model.connection, onSave: model.save) }
        .task { model.startOnLaunch() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "server.rack").font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.accent).frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("homelab").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text("MISSION CONTROL").font(.system(size: 8, weight: .medium)).tracking(2).foregroundStyle(Theme.muted)
                }
            }.padding(.horizontal, 22).padding(.top, 25).padding(.bottom, 38)
            Eyebrow(text: "Workspace").padding(.horizontal, 24).padding(.bottom, 12)
            ForEach(Screen.allCases) { screen in
                Button { model.screen = screen } label: {
                    HStack(spacing: 12) {
                        Image(systemName: screen.icon).font(.system(size: 15)).frame(width: 20)
                        Text(screen.rawValue).font(.system(size: 13, weight: model.screen == screen ? .semibold : .regular))
                        Spacer()
                        if model.screen == screen { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                    }.foregroundStyle(model.screen == screen ? Theme.accent : Theme.secondary)
                        .padding(.horizontal, 13).padding(.vertical, 12)
                        .background(model.screen == screen ? Theme.accent.opacity(0.085) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 4)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(model.healthy ? Theme.accent : Theme.muted).frame(width: 7, height: 7)
                    Text(model.snapshot?.hostname ?? "homelab").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "lock.shield").foregroundStyle(Theme.muted)
                }
                Text(model.connection.destination).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                Divider().overlay(Theme.line)
                Button { model.showingSettings = true } label: {
                    Label("Configurações", systemImage: "slider.horizontal.3").font(.system(size: 12))
                }.buttonStyle(.plain).foregroundStyle(Theme.secondary)
            }.padding(16).background(Theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12)).padding(12)
        }.background(Theme.sidebar)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.screen.rawValue).font(.system(size: 25, weight: .semibold))
                Text(model.screen.subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            StatusBadge(title: model.status, color: model.healthy ? Theme.accent : .orange)
            Button { model.monitoring ? model.pause() : model.start() } label: {
                Image(systemName: model.monitoring ? "pause" : "play")
            }.help(model.monitoring ? "Pausar monitoramento" : "Retomar monitoramento")
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Atualizar todos os dados").keyboardShortcut("r", modifiers: .command)
            if model.screen != .terminal {
                Button { model.screen = .terminal } label: { Label("Terminal", systemImage: "terminal") }
            }
        }.buttonStyle(.bordered).controlSize(.regular).padding(.horizontal, 28).padding(.vertical, 23)
    }

    @ViewBuilder private var notices: some View {
        if !model.monitoring {
            Label("Monitoramento pausado. Os valores exibidos são da última coleta.", systemImage: "pause.circle")
                .font(.system(size: 12)).foregroundStyle(.orange)
        }
        if !model.warnings.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(Set(model.warnings)).sorted(), id: \.self) { Text($0).textSelection(.enabled) }
                    if model.errors[.fast] != nil {
                        Text("Confira a conexão nas configurações. Para autenticar ou confirmar a chave do servidor, abra o Terminal do app.")
                        Button("Abrir terminal") { model.screen = .terminal }
                    }
                }.font(.system(size: 12)).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label(model.errors.isEmpty ? "Algumas métricas estão indisponíveis" : "Falha de atualização · valores anteriores podem estar desatualizados", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .medium))
            }.foregroundStyle(.orange).padding(14).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var terminalPage: some View {
        VStack(spacing: 12) {
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.terminals) { session in
                            HStack(spacing: 10) {
                                Button(session.name) { model.activeTerminal = session.id }
                                Button { model.closeTerminal(session) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.help("Encerrar sessão")
                            }.buttonStyle(.plain).font(.system(size: 12))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .foregroundStyle(model.activeTerminal == session.id ? Theme.accent : Theme.secondary)
                                .background(model.activeTerminal == session.id ? Theme.accent.opacity(0.1) : Theme.card, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                Button { model.addTerminal() } label: { Image(systemName: "plus") }.help("Nova sessão SSH").keyboardShortcut("t", modifiers: .command)
            }
            TerminalPane(session: model.currentTerminal, connection: model.connection).id(model.activeTerminal)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 9))
            Text("SSH criptografado")
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if let date = model.snapshot?.timestamp {
                    Text("Última coleta \(date, style: .relative) atrás")
                } else { Text("Aguardando primeira coleta") }
            }
        }.font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.horizontal, 28).padding(.vertical, 11)
    }
}

struct StatusBadge: View {
    let title: String
    var color: Color = Theme.accent
    var body: some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(.system(size: 11, weight: .medium)) }
            .foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 6).background(color.opacity(0.09), in: Capsule())
    }
}

struct ConnectionSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State var connection: Connection
    let onSave: (Connection) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Conexão com o homelab").font(.title2.weight(.semibold))
            Text("Use um endereço IP ou um host do seu ~/.ssh/config. As chaves e o agente SSH do Mac são usados automaticamente.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Host", text: $connection.host)
                TextField("Usuário", text: $connection.user, prompt: Text("Opcional para hosts do SSH config"))
                TextField("Porta", value: $connection.port, format: .number.grouping(.never))
                Section("Atualização automática") {
                    Picker("CPU / RAM / GPU", selection: $connection.interval) { ForEach(2...5, id: \.self) { Text("\($0) segundos").tag(Double($0)) } }
                    Picker("Docker / Ollama", selection: $connection.servicesInterval) { ForEach(5...10, id: \.self) { Text("\($0) segundos").tag(Double($0)) } }
                    Picker("Disco / uptime", selection: $connection.systemInterval) { ForEach([30, 35, 40, 45, 50, 55, 60], id: \.self) { Text("\($0) segundos").tag(Double($0)) } }
                }
            }.formStyle(.grouped).frame(height: 285)
            Text("Salvar encerra as sessões SSH atuais e reconecta o monitor. O app não armazena senhas.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Salvar e conectar") { onSave(connection); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(!connection.isValid).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 500).preferredColorScheme(.dark)
    }
}
