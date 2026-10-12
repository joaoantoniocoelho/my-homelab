import AppKit
import UniformTypeIdentifiers
import HomelabCore

/// Hands a generated `.rdp` file to an installed client. Any app that opens `.rdp` documents works,
/// so supporting another client is a bundle identifier, not new code.
enum RemoteDesktopLauncher {
    struct Client: Identifiable, Hashable { let id: String; let name: String }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Homelab/RDP", isDirectory: true)
    }

    @MainActor static func clients() -> [Client] {
        guard let type = UTType(filenameExtension: "rdp") else { return [] }
        let found = NSWorkspace.shared.urlsForApplications(toOpen: type).compactMap { url -> Client? in
            guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
            return Client(id: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        return Array(Set(found)).sorted { $0.name < $1.name }
    }

    @MainActor static func name(of bundleIdentifier: String) -> String {
        if bundleIdentifier.isEmpty { return "Padrão do sistema" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleIdentifier == VirtualMachineConfig.windowsApp ? "Windows App" : bundleIdentifier
    }

    @MainActor static func launch(_ config: VirtualMachineConfig) async throws {
        let file = try RDPFile.write(name: config.name, port: config.localPort, username: config.guestUser, display: config.display, in: directory)
        if config.rdpClient.isEmpty {
            guard NSWorkspace.shared.open(file) else { throw VMError.clientUnavailable("nenhum app abre arquivos .rdp") }
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.rdpClient) else {
            throw VMError.clientUnavailable("\(name(of: config.rdpClient)) não está instalado")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: configuration)
    }
}
