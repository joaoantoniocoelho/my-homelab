import AppKit
import SwiftUI
import SwiftTerm
import HomelabCore

@MainActor final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let name: String
    let command: String?
    var number: Int { Int(name.split(separator: " ").last ?? "1") ?? 1 }
    @Published private(set) var running = false
    @Published private(set) var started = false
    @Published private(set) var status = "Pronto para conectar"
    @Published private(set) var view: LocalProcessTerminalView
    @Published var fontSize: CGFloat = 13 { didSet { view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) } }

    init(name: String, command: String? = nil) {
        self.name = name; self.command = command
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        super.init(); configure(view)
    }
    private func configure(_ terminal: LocalProcessTerminalView) {
        terminal.processDelegate = self
        terminal.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(red: 0.035, green: 0.048, blue: 0.065, alpha: 1)
        terminal.nativeForegroundColor = NSColor(red: 0.82, green: 0.87, blue: 0.89, alpha: 1)
    }
    func start(_ connection: Connection) {
        guard !running, connection.isValid else { return }
        if started {
            view.processDelegate = nil
            view = LocalProcessTerminalView(frame: view.frame)
            configure(view)
        }
        started = true; running = true; status = "SSH em execução"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        view.startProcess(executable: "/usr/bin/ssh", args: connection.arguments(interactive: true, command: command),
                          environment: environment.map { "\($0.key)=\($0.value)" })
    }
    func stop() {
        guard running else { return }
        view.terminate(); running = false; status = "Sessão encerrada"
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) { }
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) { }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { }
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self, source === self.view else { return }
            self.running = false
            self.status = exitCode == 0 ? "Sessão encerrada" : "SSH encerrou · código \(exitCode.map(String.init) ?? "desconhecido")"
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if terminal.superview !== nsView { attach(to: nsView) }
    }
    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}

struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    let connection: Connection
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(session.running ? Theme.accent : Theme.muted).frame(width: 6, height: 6)
                Text(session.status).font(.system(size: 12))
                Spacer()
                Button { session.fontSize = max(10, session.fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }.help("Diminuir fonte")
                Button { session.fontSize = min(24, session.fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }.help("Aumentar fonte")
                Divider().frame(height: 16)
                if session.running {
                    Button("Desconectar", systemImage: "stop.circle") { session.stop() }
                } else {
                    Button("Conectar", systemImage: "bolt") { session.start(connection) }
                }
            }
            .buttonStyle(.borderless).foregroundStyle(Theme.secondary).padding(14).background(Theme.card)
            Rectangle().fill(Theme.line).frame(height: 1)
            TerminalHost(terminal: session.view).padding(12).background(Color(red: 0.035, green: 0.048, blue: 0.065))
            HStack {
                Text(connection.destination).font(.system(size: 11, design: .monospaced))
                Spacer()
                Text(session.command == nil ? "⌘C copiar  ·  ⌘V colar  ·  Ctrl+C interromper" : "q sair  ·  F2 opções  ·  setas navegar")
                    .font(.system(size: 11))
            }.foregroundStyle(Theme.muted).padding(12).background(Theme.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        .onAppear { if !session.started { session.start(connection) } }
    }
}
