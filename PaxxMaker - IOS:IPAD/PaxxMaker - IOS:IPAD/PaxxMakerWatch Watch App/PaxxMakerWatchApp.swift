import SwiftUI
import WatchKit

// Background refresh: keeps the watch widget/complication current even when
// neither the watch app nor the iOS app is running. watchOS grants a limited
// budget (roughly every 15-30 min with a complication on the active face) —
// enough for "the widget shows recent values", not per-minute live data.
class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                Task {
                    // Sparse: only hit the Worker in the background while a
                    // print is actually running; otherwise this just reschedules.
                    await WatchConnectivityManager.shared.fetchDirectOnceIfActive()
                    WatchAppDelegate.scheduleNextRefresh()
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    static func scheduleNextRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(15 * 60),
            userInfo: nil
        ) { _ in }
    }
}

@main
struct PaxxMakerWatch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @StateObject private var connectivity = WatchConnectivityManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectivity)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                connectivity.refresh()
            } else if phase == .background {
                WatchAppDelegate.scheduleNextRefresh()
            }
        }
    }
}
