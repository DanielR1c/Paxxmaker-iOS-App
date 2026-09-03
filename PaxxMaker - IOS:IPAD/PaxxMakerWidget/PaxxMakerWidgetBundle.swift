//
//  PaxxMakerWidgetBundle.swift
//  PaxxMakerWidget
//
//  Created by Daniel Richter on 13.05.26.
//

import WidgetKit
import SwiftUI

@main
struct PaxxMakerWidgetBundle: WidgetBundle {
    var body: some Widget {
        PaxxMakerWidget()
        SpoolWidget()
        // (PaxxMakerWidgetControl is Xcode's template "Timer" control — it does
        // nothing and showed placeholder text in the Controls gallery, so it is
        // not part of the shipped bundle.)
        PaxxMakerWidgetLiveActivity()
    }
}
