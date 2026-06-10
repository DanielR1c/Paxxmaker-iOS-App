import SwiftUI
import UserNotifications
import WatchConnectivity
import BackgroundTasks
import ActivityKit
import UIKit

// MARK: - Shared config (used across all background paths)
private struct WatchConfig: Codable {
    var id: String; var name: String; var baseURL: String; var apiKey: String
    var cfSecret: String?
    var pushMode: String?
    var isCloudPushEnabled: Bool { pushMode == "cloudflare" && !(cfSecret?.isEmpty ?? true) }
}

// MARK: - Background URL session polling chain
// Runs independently of BGAppRefresh — each completed task wakes the app,
// updates the Live Activity, then schedules the next task ~5 min later.
// More reliable for time-sensitive state changes (print done, error).
private final class LAPollingSession: NSObject, URLSessionDelegate {
    static let shared = LAPollingSession()
    static let sessionID = "com.paxxmaker.u1.lapoll"

    lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // Schedules two tasks per printer, offset by 60 s, so iOS has two chances to
    // wake the app each cycle. Deduplication in checkPrinterStatesInBackground
    // ensures only the first completion reschedules, preventing task growth.
    func scheduleNext(configs: [WatchConfig], delay: TimeInterval = 2 * 60) {
        for config in configs where config.baseURL != "__demo__" && !config.baseURL.isEmpty {
            guard let url = URL(string: "\(config.baseURL)/printer/objects/query?print_stats&display_status&virtual_sdcard") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            if !config.apiKey.isEmpty { req.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key") }
            for offset in [TimeInterval(0), TimeInterval(30)] {
                let task = session.dataTask(with: req)
                task.earliestBeginDate = Date().addingTimeInterval(delay + offset)
                task.resume()
            }
        }
    }
}

// MARK: - iPhone → Watch connectivity
class PhoneConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = PhoneConnectivityManager()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    // Watch requests: proxy file list and print start through the iPhone
    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        let index = message["printerIndex"] as? Int ?? 0
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
              let data = defaults.data(forKey: "watch_printer_configs"),
              let configs = try? JSONDecoder().decode([WatchConfig].self, from: data),
              !configs.isEmpty else { replyHandler([:]); return }
        let cfg = configs.indices.contains(index) ? configs[index] : configs[0]
        guard !cfg.baseURL.isEmpty, cfg.baseURL != "__demo__" else { replyHandler([:]); return }

        if message["requestStatus"] as? Bool == true {
            // Watch requested current printer status — reply with the latest cached data
            if let data = defaults.data(forKey: "w_all_printers") {
                replyHandler(["printers": data])
            } else {
                replyHandler([:])
            }
        } else if message["requestFiles"] as? Bool == true {
            proxyFileList(cfg: cfg, replyHandler: replyHandler)
        } else if let filename = message["startPrint"] as? String {
            proxyStartPrint(cfg: cfg, filename: filename, replyHandler: replyHandler)
        } else if let filename = message["requestThumbnail"] as? String {
            proxyThumbnail(cfg: cfg, filename: filename, replyHandler: replyHandler)
        } else {
            replyHandler([:])
        }
    }

    private func proxyFileList(cfg: WatchConfig, replyHandler: @escaping ([String: Any]) -> Void) {
        guard let url = URL(string: "\(cfg.baseURL)/server/files/list") else { replyHandler([:]); return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if !cfg.apiKey.isEmpty { req.setValue(cfg.apiKey, forHTTPHeaderField: "X-Api-Key") }
        struct FItem: Codable { var path: String; var modified: Double }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["result"] as? [[String: Any]] else { replyHandler([:]); return }
            let items: [FItem] = results.compactMap { d in
                guard let path = (d["path"] as? String) ?? (d["filename"] as? String) else { return nil }
                let ext = (path as NSString).pathExtension.lowercased()
                guard ext == "gcode" || ext == "gco" || ext == "g" else { return nil }
                return FItem(path: path, modified: d["modified"] as? Double ?? 0)
            }.sorted { $0.modified > $1.modified }.prefix(50).map { $0 }
            if let encoded = try? JSONEncoder().encode(items) {
                replyHandler(["files": encoded])
            } else { replyHandler([:]) }
        }.resume()
    }

    private func proxyThumbnail(cfg: WatchConfig, filename: String,
                                replyHandler: @escaping ([String: Any]) -> Void) {
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename
        guard let metaURL = URL(string: "\(cfg.baseURL)/server/files/metadata?filename=\(encoded)") else {
            replyHandler([:]); return
        }
        var metaReq = URLRequest(url: metaURL, timeoutInterval: 8)
        if !cfg.apiKey.isEmpty { metaReq.setValue(cfg.apiKey, forHTTPHeaderField: "X-Api-Key") }
        URLSession.shared.dataTask(with: metaReq) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any] else { replyHandler([:]); return }
            var reply: [String: Any] = [:]
            if let et = result["estimated_time"] as? Double, et > 0 { reply["estimatedTime"] = et }
            guard let thumbs = result["thumbnails"] as? [[String: Any]], !thumbs.isEmpty else {
                replyHandler(reply); return
            }
            // Pick thumbnail closest to 300 px — good quality, safe data size for WatchConnectivity
            let sorted = thumbs.compactMap { t -> ([String: Any], Int)? in
                guard let w = t["width"] as? Int else { return nil }; return (t, w)
            }.sorted { abs($0.1 - 300) < abs($1.1 - 300) }
            guard let relPath = sorted.first?.0["relative_path"] as? String else {
                replyHandler(reply); return
            }
            let gcodeDir = (filename as NSString).deletingLastPathComponent
            let fullPath = gcodeDir.isEmpty || gcodeDir == "." ? relPath : "\(gcodeDir)/\(relPath)"
            let pathEncoded = fullPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fullPath
            guard let imgURL = URL(string: "\(cfg.baseURL)/server/files/gcodes/\(pathEncoded)") else {
                replyHandler(reply); return
            }
            var imgReq = URLRequest(url: imgURL, timeoutInterval: 8)
            if !cfg.apiKey.isEmpty { imgReq.setValue(cfg.apiKey, forHTTPHeaderField: "X-Api-Key") }
            URLSession.shared.dataTask(with: imgReq) { imgData, _, _ in
                if let imgData = imgData { reply["thumbnailData"] = imgData }
                replyHandler(reply)
            }.resume()
        }.resume()
    }

    private func proxyStartPrint(cfg: WatchConfig, filename: String,
                                  replyHandler: @escaping ([String: Any]) -> Void) {
        guard let url = URL(string: "\(cfg.baseURL)/printer/print/start") else {
            replyHandler(["ok": false]); return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !cfg.apiKey.isEmpty { req.setValue(cfg.apiKey, forHTTPHeaderField: "X-Api-Key") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["filename": filename])
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            replyHandler(["ok": (resp as? HTTPURLResponse)?.statusCode == 200])
        }.resume()
    }
}

private let bgPrinterTaskID = "com.paxxmaker.u1.statuscheck"

// MARK: - AppDelegate for APNs token handling
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        CloudflarePushService.shared.storeDeviceToken(token)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // APNs unavailable (simulator or no entitlement) — not critical
    }

    // Fallback: when a Cloudflare alert push arrives (app in background or foreground),
    // end any matching Live Activity in case the ActivityKit push failed or token expired.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let event = userInfo["event"] as? String,
              let printerName = userInfo["printer_id"] as? String,
              event == "complete" || event == "error" || event == "cancelled" else {
            completionHandler(.noData)
            return
        }
        Task {
            let dismissDelay: TimeInterval = event == "complete" ? 15 : 4
            for activity in Activity<PaxxMakerWidgetAttributes>.activities
                where activity.attributes.printerName == printerName {
                await activity.end(
                    .init(state: activity.content.state, staleDate: nil),
                    dismissalPolicy: .after(Date().addingTimeInterval(dismissDelay))
                )
            }
            completionHandler(.newData)
        }
    }
}

@main
struct Paxxmaker_U1App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                if granted {
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            }
        PhoneConnectivityManager.shared.activate()
        // Re-attach pushTokenUpdates observers on every app launch (including background wakes).
        // This is the only reliable way to keep activity tokens registered after app termination.
        Task {
            guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
                  let data = defaults.data(forKey: "watch_printer_configs"),
                  let configs = try? JSONDecoder().decode([WatchConfig].self, from: data) else { return }
            var secretsByName: [String: String] = [:]
            for c in configs where c.isCloudPushEnabled {
                if let s = c.cfSecret { secretsByName[c.name] = s }
            }
            for activity in Activity<PaxxMakerWidgetAttributes>.activities {
                guard let secret = secretsByName[activity.attributes.printerName] else { continue }
                let printerName = activity.attributes.printerName
                Task {
                    for await tokenData in activity.pushTokenUpdates {
                        let token = tokenData.map { String(format: "%02x", $0) }.joined()
                        try? await CloudflarePushService.shared.registerActivityToken(
                            workerURL: CloudflarePushService.workerURL,
                            printerID: printerName,
                            activityToken: token,
                            secret: secret
                        )
                    }
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                schedulePrinterStatusCheck()
                scheduleURLSessionPollIfPrinting()
                // Immediately run one status check so the LA updates right away instead of
                // waiting for iOS to schedule the next URL-session background task.
                let bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "la-immediate-update") {}
                Task {
                    await checkPrinterStatesInBackground(rescheduleURLSession: false)
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                }
            }
        }
        // BGAppRefresh fallback (~15 min, iOS-controlled)
        .backgroundTask(.appRefresh(bgPrinterTaskID)) {
            await checkPrinterStatesInBackground(rescheduleURLSession: true)
        }
        // URL session chain (~5 min, more reliable for Live Activity)
        .backgroundTask(.urlSession(LAPollingSession.sessionID)) {
            await checkPrinterStatesInBackground(rescheduleURLSession: true)
        }
    }

    private func schedulePrinterStatusCheck() {
        let request = BGAppRefreshTaskRequest(identifier: bgPrinterTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func scheduleURLSessionPollIfPrinting() {
        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
              let data = defaults.data(forKey: "watch_printer_configs"),
              let configs = try? JSONDecoder().decode([WatchConfig].self, from: data) else { return }
        let states = (defaults.dictionary(forKey: "bg_prev_print_states") as? [String: String]) ?? [:]
        let printingConfigs = configs.filter { states[$0.id] == "printing" || states[$0.id] == "paused" }
        guard !printingConfigs.isEmpty else { return }
        // Reset timestamp so the first background completion always schedules the next cycle
        defaults.set(0.0, forKey: "bg_last_schedule_time")
        LAPollingSession.shared.scheduleNext(configs: printingConfigs, delay: 0)
    }

    private func checkPrinterStatesInBackground(rescheduleURLSession: Bool = false) async {
        schedulePrinterStatusCheck()

        guard let defaults = UserDefaults(suiteName: "group.paxxmaker.u1"),
              let data = defaults.data(forKey: "watch_printer_configs"),
              let configs = try? JSONDecoder().decode([WatchConfig].self, from: data) else { return }

        var states = (defaults.dictionary(forKey: "bg_prev_print_states") as? [String: String]) ?? [:]
        var stillPrinting: [WatchConfig] = []

        for config in configs where config.baseURL != "__demo__" && !config.baseURL.isEmpty {
            guard let url = URL(string: "\(config.baseURL)/printer/objects/query?print_stats&display_status&virtual_sdcard") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 10)
            if !config.apiKey.isEmpty { req.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key") }

            guard let (responseData, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let status = result["status"] as? [String: Any],
                  let ps = status["print_stats"] as? [String: Any],
                  let newState = ps["state"] as? String else { continue }

            let prevState = states[config.id] ?? "unknown"
            states[config.id] = newState

            let dispProg = (status["display_status"] as? [String: Any])?["progress"] as? Double
            let progress = dispProg ?? (status["virtual_sdcard"] as? [String: Any])?["progress"] as? Double ?? 0.0
            let timeElapsed = (ps["print_duration"] as? Double).map { Int($0) } ?? 0
            let liveState   = PaxxMakerWidgetAttributes.ContentState(
                printState: newState, progress: progress,
                extruderTemp: 0, bedTemp: 0, timeElapsed: timeElapsed
            )

            for activity in Activity<PaxxMakerWidgetAttributes>.activities
                where activity.attributes.printerName == config.name {
                if newState == "printing" || newState == "paused" {
                    await activity.update(.init(state: liveState, staleDate: nil))
                    // Re-register push token on every background wake (covers KV-cleared tokens)
                    if config.isCloudPushEnabled,
                       let secret = config.cfSecret, !secret.isEmpty,
                       let tokenData = activity.pushToken {
                        let token = tokenData.map { String(format: "%02x", $0) }.joined()
                        let printerName = config.name
                        Task.detached {
                            try? await CloudflarePushService.shared.registerActivityToken(
                                workerURL: CloudflarePushService.workerURL,
                                printerID: printerName,
                                activityToken: token,
                                secret: secret
                            )
                        }
                    }
                } else if newState == "complete" || newState == "error" || newState == "standby" {
                    await activity.end(
                        .init(state: liveState, staleDate: nil),
                        dismissalPolicy: .after(Date().addingTimeInterval(30))
                    )
                }
            }

            // Auto-start Live Activity from background when printing and no widget exists.
            // Ensures the push token is registered even if the user never opened the app during a print.
            if config.isCloudPushEnabled,
               (newState == "printing" || newState == "paused"),
               let secret = config.cfSecret, !secret.isEmpty,
               Activity<PaxxMakerWidgetAttributes>.activities.first(where: { $0.attributes.printerName == config.name }) == nil,
               let activity = try? Activity.request(
                   attributes: PaxxMakerWidgetAttributes(printerName: config.name, filename: ""),
                   content: ActivityContent(state: liveState, staleDate: nil),
                   pushType: .token
               ), let tokenData = activity.pushToken {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                let printerName = config.name
                Task.detached {
                    try? await CloudflarePushService.shared.registerActivityToken(
                        workerURL: CloudflarePushService.workerURL,
                        printerID: printerName,
                        activityToken: token,
                        secret: secret
                    )
                }
            }

            if prevState == "printing" && newState == "complete" {
                let content = UNMutableNotificationContent()
                content.title = "Druck fertig!"
                content.body = config.name
                content.sound = .default
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "print-done-\(config.name)", content: content, trigger: nil))
            } else if prevState == "printing" && newState == "error" {
                let content = UNMutableNotificationContent()
                content.title = "Druckfehler"
                content.body = config.name
                content.sound = .default
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "print-err-\(config.name)", content: content, trigger: nil))
            }

            if newState == "printing" || newState == "paused" {
                stillPrinting.append(config)
            }
        }

        defaults.set(states, forKey: "bg_prev_print_states")

        // Keep the URL session chain alive. Dedup: only the first of the two staggered
        // tasks schedules the next cycle; the second (firing ~30 s later) is suppressed.
        if rescheduleURLSession && !stillPrinting.isEmpty {
            let now = Date().timeIntervalSince1970
            let lastSchedule = defaults.double(forKey: "bg_last_schedule_time")
            if now - lastSchedule > 90 {
                defaults.set(now, forKey: "bg_last_schedule_time")
                LAPollingSession.shared.scheduleNext(configs: stillPrinting)
            }
        }
    }
}
