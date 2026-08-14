import Foundation

// Shelly LAN REST API — supports Gen1 (Shelly Plug S, 1, 2, …) and Gen2+ (Plus, Pro, Mini)
// Gen1: HTTP GET /relay/0          → {"ison": Bool}
//       HTTP GET /relay/0?turn=on|off
//       HTTP GET /meter/0          → {"power": Double}
// Gen2: HTTP GET /rpc/Switch.GetStatus?id=0 → {"output": Bool, "apower": Double}
//       HTTP POST /rpc/Switch.Set  body: {"id":0,"on":Bool}
// Detection: tries Gen1 first; on parse failure falls back to Gen2.

enum ShellyLocalService {

    static func getStatus(host: String) async throws -> PlugStatus {
        if let result = try? await gen1Status(host: host) { return result }
        return try await gen2Status(host: host)
    }

    static func setPower(_ on: Bool, host: String) async throws {
        if (try? await gen1Set(on, host: host)) != nil { return }
        try await gen2Set(on, host: host)
    }

    // MARK: Gen1

    private static func gen1Status(host: String) async throws -> PlugStatus {
        let url = try localURL("http://\(host)/relay/0")
        let (data, resp) = try await session.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ShellyError.badStatus }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ison = json["ison"] as? Bool else { throw ShellyError.parseFailure }
        // Try to get power from /meter/0
        let watts = try? await gen1Meter(host: host)
        return PlugStatus(power: ison, watts: watts)
    }

    private static func gen1Meter(host: String) async throws -> Double {
        let url = try localURL("http://\(host)/meter/0")
        let (data, resp) = try await session.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ShellyError.badStatus }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ShellyError.parseFailure }
        if let w = json["power"] as? Double { return w }
        if let w = json["power"] as? Int    { return Double(w) }
        throw ShellyError.parseFailure
    }

    private static func gen1Set(_ on: Bool, host: String) async throws {
        let url = try localURL("http://\(host)/relay/0?turn=\(on ? "on" : "off")")
        let (_, resp) = try await session.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ShellyError.badStatus }
    }

    // MARK: Gen2

    private static func gen2Status(host: String) async throws -> PlugStatus {
        let url = try localURL("http://\(host)/rpc/Switch.GetStatus?id=0")
        let (data, resp) = try await session.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ShellyError.badStatus }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? Bool else { throw ShellyError.parseFailure }
        let watts: Double?
        if let w = json["apower"] as? Double     { watts = w }
        else if let w = json["apower"] as? Int   { watts = Double(w) }
        else { watts = nil }
        return PlugStatus(power: output, watts: watts)
    }

    private static func gen2Set(_ on: Bool, host: String) async throws {
        let url = try localURL("http://\(host)/rpc/Switch.Set")
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": 0, "on": on])
        let (_, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ShellyError.badStatus }
    }

    // MARK: Helpers

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 6
        return URLSession(configuration: cfg)
    }()

    private static func localURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw ShellyError.badURL }
        return url
    }

    enum ShellyError: LocalizedError {
        case badURL, badStatus, parseFailure
        var errorDescription: String? {
            switch self {
            case .badURL:       return "Invalid Shelly IP address"
            case .badStatus:    return "Shelly returned an error"
            case .parseFailure: return "Could not read Shelly response"
            }
        }
    }
}
