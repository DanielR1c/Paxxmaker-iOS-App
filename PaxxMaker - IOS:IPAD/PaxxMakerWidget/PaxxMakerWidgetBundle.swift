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
        if #available(iOS 18.0, *) {
            PaxxMakerWidgetControl()
        }
        PaxxMakerWidgetLiveActivity()
    }
}
