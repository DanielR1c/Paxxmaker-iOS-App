import Foundation

// MARK: - Cloudflare Push Service
// Manages APNs device token and Live Activity token registration with the Cloudflare Worker.
// The Python script on the printer polls Moonraker and sends progress/state updates
// to the Worker, which forwards them as Live Activity push updates.

final class CloudflarePushService {
    static let shared = CloudflarePushService()
    private init() {}

    static let workerURL = "https://paxxmaker-push.........workers.dev"

    private let tokenKey = "apns_device_token"

    var storedDeviceToken: String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    func storeDeviceToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: tokenKey)
        // Re-register for all printers that have push enabled
        if let data = UserDefaults.standard.data(forKey: "printers_config"),
           let configs = try? JSONDecoder().decode([PrinterConfigLite].self, from: data) {
            for cfg in configs {
                guard cfg.pushMode == "cloudflare",
                      let secret = cfg.cloudflareNotifySecret, !secret.isEmpty else { continue }
                let s = secret; let n = cfg.name
                Task {
                    try? await self.registerDeviceToken(
                        workerURL: Self.workerURL,
                        printerID: n,
                        deviceToken: token,
                        secret: s
                    )
                }
            }
        }
    }

    private struct PrinterConfigLite: Decodable {
        var name: String
        var pushMode: String?
        var cloudflareNotifySecret: String?
    }

    // MARK: - Worker Endpoints

    func registerDeviceToken(workerURL: String, printerID: String, deviceToken: String, secret: String) async throws {
        let url = try endpoint(base: workerURL, path: "/register-device")
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "printer_id":   printerID,
            "device_token": deviceToken,
            "secret":       secret,
            "locale":       Locale.preferredLanguages.first ?? "de",
            "sandbox":      Self.isSandbox
        ])
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 201 else { throw PushError.workerError(code) }
    }

    func registerActivityToken(workerURL: String, printerID: String, activityToken: String, secret: String) async throws {
        let url = try endpoint(base: workerURL, path: "/register-activity")
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "printer_id":     printerID,
            "activity_token": activityToken,
            "secret":         secret
        ])
        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 201 else { throw PushError.workerError(code) }
    }

    /// Removes all KV entries for a printer — call when user deletes a printer or disables push.
    func cleanupPrinter(workerURL: String, printerID: String, secret: String) async {
        guard let url = try? endpoint(base: workerURL, path: "/cleanup") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "secret": secret
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    func unregisterDeviceToken(workerURL: String, printerID: String, secret: String, deviceToken: String) async {
        guard let url = try? endpoint(base: workerURL, path: "/unregister-device") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "secret":       secret,
            "device_token": deviceToken
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Python Script Generation

    /// Generates the bridge script content with credentials embedded.
    /// The app shows this to the user as SSH copy-paste commands.
    func generatePythonScript(printerID: String, workerURL: String, secret: String) -> String {
        return """
        #!/usr/bin/env python3
        # PaxxMaker Push Bridge — generiert von der App, nicht manuell bearbeiten
        import urllib.request, urllib.error, json, time, signal, sys

        MOONRAKER_HOST = "http://localhost:7125"
        WORKER_URL     = "\(workerURL)"
        PRINTER_ID     = "\(printerID)"
        SECRET         = "\(secret)"

        POLL_PRINTING  = 10
        POLL_IDLE      = 60
        TIMEOUT        = 5
        PROG_THRESHOLD = 0.01

        running = True
        last_state = None
        last_progress = -1

        def stop(sig, frame):
            global running
            running = False

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT,  stop)

        def get(url):
            try:
                with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
                    return json.loads(r.read())
            except:
                return None

        def post(data):
            try:
                b = json.dumps(data).encode()
                req = urllib.request.Request(WORKER_URL + "/update", data=b, method="POST")
                req.add_header("Content-Type", "application/json")
                with urllib.request.urlopen(req, timeout=TIMEOUT):
                    pass
            except:
                pass

        def get_status():
            r = get(f"{MOONRAKER_HOST}/printer/objects/query?print_stats&virtual_sdcard&extruder&heater_bed")
            if not r:
                return None
            s  = r.get("result", {}).get("status", {})
            ps = s.get("print_stats", {})
            vs = s.get("virtual_sdcard", {})
            ex = s.get("extruder", {})
            hb = s.get("heater_bed", {})
            return {
                "state":          ps.get("state", "standby"),
                "filename":       ps.get("filename", ""),
                "progress":       vs.get("progress", 0.0),
                "print_duration": ps.get("print_duration", 0),
                "hotend_temp":    round(ex.get("temperature", 0), 1),
                "bed_temp":       round(hb.get("temperature", 0), 1),
            }

        def send(status, event):
            post({
                "printer_id": PRINTER_ID,
                "secret":     SECRET,
                "event":      event,
                **status
            })

        while running:
            s = get_status()
            if s is None:
                time.sleep(POLL_IDLE)
                continue
            state = s["state"]
            prog  = s["progress"]
            if state != last_state:
                if state == "printing":
                    send(s, "started"); last_progress = prog
                elif state == "paused" and last_state == "printing":
                    send(s, "paused")
                elif state == "printing" and last_state == "paused":
                    send(s, "resumed")
                elif state in ("complete", "error", "cancelled"):
                    send(s, state); last_progress = -1
                last_state = state
            elif state == "printing" and abs(prog - last_progress) >= PROG_THRESHOLD:
                send(s, "progress"); last_progress = prog
            time.sleep(POLL_PRINTING if state == "printing" else POLL_IDLE)
        """
    }

    /// Generates the systemd service file with memory limits.
    func generateServiceFile(scriptPath: String) -> String {
        return """
        [Unit]
        Description=PaxxMaker Push Bridge
        After=network.target

        [Service]
        Type=simple
        ExecStart=/usr/bin/python3 \(scriptPath)
        Restart=on-failure
        RestartSec=10
        MemoryMax=30M
        CPUQuota=5%
        PrivateTmp=true
        ProtectSystem=strict
        StandardOutput=null
        StandardError=null

        [Install]
        WantedBy=default.target
        """
    }

    // MARK: - Helpers

    private func endpoint(base: String, path: String) throws -> URL {
        let trimmed = base.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)\(path)") else { throw PushError.invalidURL }
        return url
    }

    static var isSandbox: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func generateSecret() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<32).compactMap { _ in chars.randomElement() })
    }

    // MARK: - Errors

    enum PushError: LocalizedError {
        case invalidURL
        case workerError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:         return "Ungültige URL"
            case .workerError(let c): return "Cloudflare Worker Fehler (HTTP \(c))"
            }
        }
    }
}
