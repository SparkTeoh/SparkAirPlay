//
//  AirPlayManager.swift
//  SparkAirPlay
//
//  Created by Spark Liang on 28/07/2025.
//

import Foundation
import SwiftUI
import AVFoundation
import Network

/// Main manager class that handles AirPlay receiver functionality
class AirPlayManager: ObservableObject {
    @Published var isConnected = false
    @Published var connectionStatus = "Waiting for connection..."
    @Published var connectedDevice: String?
    @Published var videoLayer: AVSampleBufferDisplayLayer?
    
    private var receiverService: AirPlayReceiverService?
    private var videoDecoder: VideoDecoder?
    
    init() {
        setupAirPlayReceiver()
    }
    
    private func setupAirPlayReceiver() {
        receiverService = AirPlayReceiverService.shared
        receiverService?.delegate = self
        
        // Initialize video decoder
        videoDecoder = VideoDecoder()
        
        // Create video display layer
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor.black
        
        DispatchQueue.main.async {
            self.videoLayer = layer
        }
        
        videoDecoder?.outputLayer = layer
    }
    
    func disconnect() {
        receiverService?.disconnectCurrentClient()
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectedDevice = nil
            self.connectionStatus = "Disconnected"
            self.videoLayer?.flushAndRemoveImage()
        }
    }
    
    func startReceiver() {
        receiverService?.startService()
    }
    
    func stopReceiver() {
        receiverService?.stopService()
    }
}

// MARK: - AirPlayReceiverDelegate
extension AirPlayManager: AirPlayReceiverDelegate {
    func airPlayDidConnect(from device: String) {
        DispatchQueue.main.async {
            self.isConnected = true
            self.connectedDevice = device
            self.connectionStatus = "Connected to \(device)"
        }
        
        print("📱 AirPlay connected from: \(device)")
    }
    
    func airPlayDidDisconnect() {
        DispatchQueue.main.async {
            // Only update UI if we were actually connected for streaming
            // Don't change status for probe disconnections
            if self.isConnected {
                self.isConnected = false
                self.connectedDevice = nil
                self.connectionStatus = "Disconnected"
                self.videoLayer?.flushAndRemoveImage()
                print("📱 AirPlay streaming disconnected")
            } else {
                print("📱 AirPlay probe disconnected (keeping service running)")
            }
        }
    }
    
    func airPlayDidReceiveVideo(data: Data) {
        // Decode and display video frame
        videoDecoder?.decodeFrame(data: data)
    }
    
    func airPlayDidReceiveError(_ error: Error) {
        DispatchQueue.main.async {
            self.connectionStatus = "Error: \(error.localizedDescription)"
        }
        
        print("❌ AirPlay error: \(error)")
    }
}