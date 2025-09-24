//
//  NextBusApp.swift
//  NextBus
//
//  Created by Tejas Patel on 9/24/25.
//

import SwiftUI
import CoreData

@main
struct NextBusApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
