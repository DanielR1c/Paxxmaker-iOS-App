import SwiftUI

@main
struct PaxxMakerWatch_Watch_AppApp: App {
    @StateObject private var connectivity = WatchConnectivityManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectivity)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                connectivity.refresh()
            }
        }
    }
}
