import Foundation

public struct Connection: Codable, Equatable, Sendable {
    public var host: String
    public var user: String
    public var port: Int
    public var interval: Double
    public var servicesInterval: Double
    public var systemInterval: Double

    public init(host: String = "homelab", user: String = "", port: Int = 22, interval: Double = 3, servicesInterval: Double = 8, systemInterval: Double = 45) {
        self.host = host; self.user = user; self.port = port; self.interval = interval
        self.servicesInterval = servicesInterval; self.systemInterval = systemInterval
    }

    public var destination: String { user.isEmpty ? host : "\(user)@\(host)" }
    public var isValid: Bool {
        let hostChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:[]")
        let userChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return !host.isEmpty && !host.hasPrefix("-") && host.unicodeScalars.allSatisfy(hostChars.contains)
            && !user.hasPrefix("-") && user.unicodeScalars.allSatisfy(userChars.contains)
            && (1...65535).contains(port) && (2...5).contains(interval)
            && (5...10).contains(servicesInterval) && (30...60).contains(systemInterval)
    }

    public func arguments(interactive: Bool, command: String? = nil) -> [String] {
        var args = ["-p", String(port), "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
        args += interactive ? ["-tt"] : ["-T", "-o", "BatchMode=yes"]
        args += ["--", destination]
        if let command { args.append(command) }
        return args
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
