//
//  SparkAirPlayApp.swift
//  SparkAirPlay
//
//  Created by Spark Liang on 28/07/2025.
//

import SwiftUI

@main
struct SparkAirPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure app for AirPlay receiver functionality
        setupAirPlayReceiver()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    private func setupAirPlayReceiver() {
        // Initialize AirPlay receiver service
        AirPlayReceiverService.shared.startService()
    }
}
