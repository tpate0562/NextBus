//
//  NextBusWidgetBundle.swift
//  NextBusWidget
//
//  Created by Tejas Patel on 4/16/26.
//

import WidgetKit
import SwiftUI

@main
struct NextBusWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextBusSmallWidget()
        NextBusMediumWidget()
        NextBusLargeWidget()
    }
}
