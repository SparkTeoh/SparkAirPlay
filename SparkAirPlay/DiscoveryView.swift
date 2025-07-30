//
//  DiscoveryView.swift
//  SparkAirPlay
//
//  Created by Spark Liang on 28/07/2025.
//

import SwiftUI

/// Discovery view that shows AirPlay connection status and available devices
struct DiscoveryView: View {
    @ObservedObject var airPlayManager: AirPlayManager
    @State private var isServiceRunning = false
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // AirPlay icon and title
            VStack(spacing: 20) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)
                
                Text("SparkAirPlay Receiver")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
            }
            
            // Status section
            VStack(spacing: 15) {
                Text("Status")
                    .font(.headline)
                    .foregroundColor(.gray)
                
                Text(airPlayManager.connectionStatus)
                    .font(.title2)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                // Service status indicator
                HStack {
                    Circle()
                        .fill(isServiceRunning ? Color.green : Color.red)
                        .frame(width: 12, height: 12)
                    
                    Text(isServiceRunning ? "Service Running" : "Service Stopped")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            
            // Instructions
            VStack(spacing: 10) {
                Text("How to Connect")
                    .font(.headline)
                    .foregroundColor(.gray)
                
                VStack(alignment: .leading, spacing: 8) {
                    InstructionRow(
                        icon: "iphone",
                        text: "Open Control Center on your iPhone or iPad"
                    )
                    
                    InstructionRow(
                        icon: "airplayaudio",
                        text: "Tap the AirPlay button"
                    )
                    
                    InstructionRow(
                        icon: "desktopcomputer",
                        text: "Select \"SparkAirPlay\" from the list"
                    )
                    
                    InstructionRow(
                        icon: "play.circle",
                        text: "Start playing content to begin streaming"
                    )
                }
                .padding(.horizontal, 40)
            }
            
            // Control buttons
            HStack(spacing: 20) {
                Button(action: {
                    if isServiceRunning {
                        airPlayManager.stopReceiver()
                    } else {
                        airPlayManager.startReceiver()
                    }
                    isServiceRunning.toggle()
                }) {
                    HStack {
                        Image(systemName: isServiceRunning ? "stop.circle" : "play.circle")
                        Text(isServiceRunning ? "Stop Service" : "Start Service")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Button("Full Screen") {
                    toggleFullScreen()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            
            Spacer()
            
            // Network info
            VStack(spacing: 5) {
                Text("Network Information")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Text("Service: _airplay._tcp.")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Text("Port: 7000")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                if let deviceName = getDeviceName() {
                    Text("Device: \(deviceName)")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(40)
        .background(Color.black)
        .onAppear {
            airPlayManager.startReceiver()
            isServiceRunning = true
        }
    }
    
    private func toggleFullScreen() {
        guard let window = NSApplication.shared.windows.first else { return }
        
        window.collectionBehavior = [
            .fullScreenPrimary,
            .fullScreenAllowsTiling,
            .managed
        ]
        
        window.toggleFullScreen(nil)
    }
    
    private func getDeviceName() -> String? {
        return Host.current().localizedName
    }
}

struct InstructionRow: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.blue)
                .frame(width: 20)
            
            Text(text)
                .font(.body)
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
            
            Spacer()
        }
    }
}

#Preview {
    DiscoveryView(airPlayManager: AirPlayManager())
        .background(Color.black)
}