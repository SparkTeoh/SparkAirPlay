import SwiftUI

struct ContentView: View {
    @StateObject private var airPlayManager = AirPlayManager()
    @State private var isFullScreen = false
    
    var body: some View {
        ZStack {
            if airPlayManager.isConnected {
                // Full-screen video view when connected
                AirPlayVideoView(videoLayer: airPlayManager.videoLayer)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        if !isFullScreen {
                            controlsOverlay
                        }
                    }
            } else {
                // Discovery view when not connected
                DiscoveryView(airPlayManager: airPlayManager)
            }
        }
        .background(Color.black)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                Spacer()
                
                Button("Full Screen") {
                    toggleFullScreen()
                }
                .buttonStyle(.borderedProminent)
                .padding()
                
                Button("Disconnect") {
                    airPlayManager.disconnect()
                }
                .buttonStyle(.bordered)
                .padding()
            }
            Spacer()
        }
    }
    
    private func toggleFullScreen() {
        guard let window = NSApplication.shared.windows.first else { return }
        
        // Configure window for proper Space behavior
        window.collectionBehavior = [
            .fullScreenPrimary,
            .fullScreenAllowsTiling,
            .managed
        ]
        
        window.toggleFullScreen(nil)
    }
}