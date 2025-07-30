//
//  AirPlayVideoView.swift
//  SparkAirPlay
//
//  Created by Spark Liang on 28/07/2025.
//

import SwiftUI
import AVFoundation

/// SwiftUI view that displays AirPlay video using AVSampleBufferDisplayLayer
struct AirPlayVideoView: NSViewRepresentable {
    let videoLayer: AVSampleBufferDisplayLayer?
    
    func makeNSView(context: Context) -> VideoDisplayView {
        let view = VideoDisplayView()
        if let layer = videoLayer {
            view.setVideoLayer(layer)
        }
        return view
    }
    
    func updateNSView(_ nsView: VideoDisplayView, context: Context) {
        if let layer = videoLayer {
            nsView.setVideoLayer(layer)
        }
    }
}

/// NSView wrapper for AVSampleBufferDisplayLayer
class VideoDisplayView: NSView {
    private var videoLayer: AVSampleBufferDisplayLayer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = CGColor.black
    }
    
    func setVideoLayer(_ videoLayer: AVSampleBufferDisplayLayer) {
        // Remove existing video layer
        self.videoLayer?.removeFromSuperlayer()
        
        // Add new video layer
        self.videoLayer = videoLayer
        
        guard let layer = self.layer else { return }
        
        videoLayer.frame = bounds
        videoLayer.videoGravity = .resizeAspect
        videoLayer.backgroundColor = CGColor.black
        
        layer.addSublayer(videoLayer)
        
        // Ensure video layer resizes with view
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }
    
    override func layout() {
        super.layout()
        videoLayer?.frame = bounds
    }
    
    override var acceptsFirstResponder: Bool {
        return false // Don't intercept swipe gestures
    }
    
    override func swipe(with event: NSEvent) {
        // Pass swipe events to the next responder (for Space switching)
        nextResponder?.swipe(with: event)
    }
    
    override func scrollWheel(with event: NSEvent) {
        // Pass scroll events to the next responder
        nextResponder?.scrollWheel(with: event)
    }
}