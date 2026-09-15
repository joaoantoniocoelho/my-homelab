import SwiftUI
import HomelabCore

@main enum EntryPoint {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            Task {
                do {
                    for group in CollectionGroup.allCases {
                        let result = try await ProcessRunner.run(arguments: Connection().arguments(interactive: false, command: Telemetry.command(group: group)))
                        guard result.status == 0 else { throw TelemetryError.invalid(result.error) }
                        let snapshot = try Telemetry.parse(result.output)
                        print("\(group.rawValue): \(snapshot.hostname) · GPU \(snapshot.gpus.count) · serviços \(snapshot.services.count) · uptime \(snapshot.uptime ?? 0)")
                        if !snapshot.warnings.isEmpty { print(snapshot.warnings.joined(separator: "\n")) }
                    }
                    exit(0)
                } catch { fputs("Falha: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            dispatchMain()
        } else { HomelabApp.main() }
    }
}

struct HomelabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Homelab", id: "main") {
            ContentView().environmentObject(model)
                .background(MainWindowObserver(delegate: delegate))
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1280, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Configurações…") { model.showingSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Servidor") {
                Button("Atualizar dados") { model.refresh() }
                Button(model.monitoring ? "Pausar monitoramento" : "Retomar monitoramento") { model.monitoring ? model.pause() : model.start() }
                Divider()
                Button("Nova sessão SSH") { model.screen = .terminal; model.addTerminal() }
                Button("Desconectar tudo") { model.disconnect() }
                Divider()
                ForEach(Array(Screen.allCases.enumerated()), id: \.element.id) { index, screen in
                    Button(screen.rawValue) { model.screen = screen }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
        MenuBarExtra("Homelab", systemImage: "server.rack") {
            HomelabMenu(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MainWindowObserver: NSViewRepresentable {
    let delegate: AppDelegate
    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.onWindow = { [weak delegate] window in delegate?.observe(window) }
        return view
    }
    func updateNSView(_ nsView: WindowProbe, context: Context) { }

    final class WindowProbe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private weak var mainWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func observe(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        mainWindow = window
        window.isReleasedWhenClosed = false
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let index = CommandLine.arguments.firstIndex(of: "--capture-ui"), CommandLine.arguments.count > index + 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            Task { await captureUI(in: directory) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { model?.disconnect() }

    // Opt-in visual verification: capture only this app's views, never the desktop.
    private func captureUI(in directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for _ in 0..<40 {
                if model?.snapshot != nil && model?.servicesData != nil && model?.systemData != nil { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let model, model.snapshot != nil, model.servicesData != nil, model.systemData != nil else {
                throw TelemetryError.invalid("A coleta inicial falhou durante a verificação visual.")
            }
            for (screen, name) in [(Screen.overview, "server"), (.gpu, "gpu"), (.ollama, "ollama"), (.services, "services"), (.terminal, "terminal")] {
                model.screen = screen
                try await Task.sleep(for: .seconds(screen == .terminal ? 3 : 1))
                guard let view = mainWindow?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw TelemetryError.invalid("Não foi possível capturar a janela do app.")
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
            }
            guard let window = mainWindow else { throw TelemetryError.invalid("Janela principal não encontrada.") }
            let session = model.currentTerminal
            let lastSample = model.snapshot?.timestamp
            window.performClose(nil)
            try await Task.sleep(for: .seconds(model.connection.interval + 2))
            guard !window.isVisible, NSApp.activationPolicy() == .accessory,
                  model.monitoring, session.running, model.snapshot?.timestamp != lastSample else {
                throw TelemetryError.invalid("A janela fechada não preservou o monitoramento e o terminal.")
            }
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            try await Task.sleep(for: .milliseconds(500))
            guard window.isVisible, NSApp.activationPolicy() == .regular, model.currentTerminal === session else {
                throw TelemetryError.invalid("Falha ao reabrir o painel preservando a sessão.")
            }
            model.pause()
            window.performClose(nil)
            try await Task.sleep(for: .milliseconds(500))
            _ = applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            try await Task.sleep(for: .milliseconds(500))
            guard !model.monitoring else { throw TelemetryError.invalid("Reabrir a janela retomou uma coleta pausada.") }
            model.start()
            let menuWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
            menuWindow.isReleasedWhenClosed = false
            let menuView = NSHostingView(rootView: HomelabMenu(model: model))
            menuWindow.contentView = menuView
            let menuSize = menuView.fittingSize
            guard menuSize.width >= 380, menuSize.height >= 500 else {
                throw TelemetryError.invalid("O painel da barra de menus colapsou ao calcular sua altura: \(menuSize).")
            }
            menuWindow.setContentSize(menuSize)
            menuWindow.center()
            menuWindow.orderFront(nil)
            try await Task.sleep(for: .milliseconds(500))
            if let bitmap = menuView.bitmapImageRepForCachingDisplay(in: menuView.bounds) {
                menuView.cacheDisplay(in: menuView.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("menubar.png"))
            }
            menuWindow.close()
            try "Telas renderizadas. Fechar/reabrir preserva monitoramento, pausa e sessão SSH.\n".write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
            model.screen = .overview
        } catch {
            try? error.localizedDescription.write(to: directory.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8)
        }
    }
}
