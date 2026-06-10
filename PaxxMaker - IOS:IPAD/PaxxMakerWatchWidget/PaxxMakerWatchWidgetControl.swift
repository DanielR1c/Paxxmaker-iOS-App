//
//  PaxxMakerWatchWidgetControl.swift
//  PaxxMakerWatchWidget
//
//  Created by Daniel Richter on 15.05.26.
//

import AppIntents
import SwiftUI
import WidgetKit

@available(watchOS 26.0, *)
struct PaxxMakerWatchWidgetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "HandyApp.Paxxmaker-U1.watchkitapp.PaxxMakerWatchWidget",
            provider: Provider()
        ) { value in
            ControlWidgetToggle(
                "Start Timer",
                isOn: value,
                action: StartTimerIntent()
            ) { isRunning in
                Label(isRunning ? "On" : "Off", systemImage: "timer")
            }
        }
        .displayName("Timer")
        .description("A an example control that runs a timer.")
    }
}

@available(watchOS 26.0, *)
extension PaxxMakerWatchWidgetControl {
    struct Provider: ControlValueProvider {
        var previewValue: Bool {
            false
        }

        func currentValue() async throws -> Bool {
            let isRunning = true // Check if the timer is running
            return isRunning
        }
    }
}

struct StartTimerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Start a timer"

    @Parameter(title: "Timer is running")
    var value: Bool

    func perform() async throws -> some IntentResult {
        // Start / stop the timer based on `value`.
        return .result()
    }
}
