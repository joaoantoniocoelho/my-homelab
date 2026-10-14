import Foundation

public enum CollectionGroup: String, CaseIterable, Sendable { case fast, services, system }

public struct GPU: Decodable, Identifiable, Sendable {
    public var id: String { uuid }
    public let index: Int
    public let name: String
    public let uuid: String
    public let driver: String
    public let temperature: Double?
    public let utilization: Double?
    public let memoryUsed: Double?
    public let memoryTotal: Double?
    public let power: Double?
    public let powerLimit: Double?
    public let fan: Double?
    public let gpuClock: Double?
    public let memoryClock: Double?
    public var memoryPercent: Double? {
        guard let used = memoryUsed, let total = memoryTotal, total > 0 else { return nil }
        return used / total * 100
    }
}

public struct GPUProcess: Decodable, Identifiable, Sendable {
    public var id: String { "\(gpuUUID)-\(pid)" }
    public let gpuUUID: String
    public let pid: Int
    public let name: String
    public let memory: Double?
}

public struct LoadedModel: Decodable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let size: Double?
    public let sizeVRAM: Double?
    public let parameterSize: String?
    public let quantization: String?
    public let expiresAt: String?
}

public struct Service: Decodable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let state: String
    public let detail: String
    public let containerCount: Int?
    public let runningCount: Int?
    public let unhealthyCount: Int?
    public var online: Bool { state == "online" }
}

public struct Snapshot: Decodable, Sendable {
    public var timestamp: Date = Date()
    public let hostname: String
    public let uptime: Double?
    public let cpu: Double?
    public let cores: Int?
    public let load: [Double]
    public let memoryUsed: Double?
    public let memoryTotal: Double?
    public let diskUsed: Double?
    public let diskTotal: Double?
    public let gpus: [GPU]
    public let processes: [GPUProcess]
    public let models: [LoadedModel]
    public let services: [Service]
    public let warnings: [String]
    public let nvtopAvailable: Bool
    enum CodingKeys: String, CodingKey {
        case hostname, uptime, cpu, cores, load, memoryUsed, memoryTotal, diskUsed, diskTotal,
             gpus, processes, models, services, warnings, nvtopAvailable
    }
}

public enum TelemetryError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public enum Telemetry {
    private static func script(_ name: String) throws -> String {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Homelab_HomelabCore.bundle")
        let resourceBundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = resourceBundle.url(forResource: name, withExtension: "py") else {
            throw TelemetryError.invalid("O coletor não foi encontrado no aplicativo. Gere o app novamente.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func command(group: CollectionGroup = .fast) throws -> String {
        "python3 -c " + Connection.shellQuote(try script("collector")) + " " + group.rawValue
    }

    /// Persistent collector: the intervals come from the app's settings, VM inventory runs `vm.py` inside the same process.
    public static func streamCommand(connection: Connection, vmInterval: Double = 15) throws -> String {
        let arguments = ["fast=\(connection.interval)", "services=\(connection.servicesInterval)",
                         "system=\(connection.systemInterval)", "vms=\(vmInterval)",
                         "vm-uri=" + LibvirtClient.uri, "vm-script=" + (try script("vm"))]
        return (["python3", "-u", "-c", Connection.shellQuote(try script("collector")), "stream"]
                + arguments.map(Connection.shellQuote)).joined(separator: " ")
    }

    public static func parse(_ output: String, at date: Date = Date()) throws -> Snapshot {
        guard let start = output.range(of: "__HL_JSON_BEGIN__\n"),
              let end = output.range(of: "\n__HL_JSON_END__", range: start.upperBound..<output.endIndex) else {
            throw TelemetryError.invalid("Resposta incompleta do servidor. Verifique se o Python 3 está disponível.")
        }
        return try decode(Data(output[start.upperBound..<end.lowerBound].utf8), at: date)
    }

    public static func decode(_ data: Data, at date: Date = Date()) throws -> Snapshot {
        do {
            var snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            snapshot.timestamp = date
            guard !snapshot.hostname.isEmpty, Set(snapshot.gpus.map(\.uuid)).count == snapshot.gpus.count,
                  snapshot.cpu.map({ (0...100).contains($0) }) ?? true else {
                throw TelemetryError.invalid("O servidor retornou métricas inválidas.")
            }
            return snapshot
        } catch let error as TelemetryError { throw error } catch {
            throw TelemetryError.invalid("Não foi possível interpretar as métricas do servidor: \(error.localizedDescription)")
        }
    }
}
