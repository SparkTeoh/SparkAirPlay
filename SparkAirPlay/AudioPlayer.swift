//
//  AudioPlayer.swift
//  SparkAirPlay
//
//  Created by Spark Liang on 28/07/2025.
//

import Foundation
import AVFoundation
import AudioToolbox

/// Audio player for handling AAC audio streams from AirPlay
class AudioPlayer {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private let audioQueue = DispatchQueue(label: "audio.player.queue")
    
    init() {
        setupAudioEngine()
    }
    
    deinit {
        audioEngine?.stop()
    }
    
    func playAudio(data: Data) {
        audioQueue.async { [weak self] in
            self?.processAudioData(data)
        }
    }
    
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        
        guard let engine = audioEngine, let player = playerNode else {
            print("❌ Failed to create audio engine")
            return
        }
        
        // Set up audio format (44.1kHz, stereo, 16-bit)
        audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
        
        guard let format = audioFormat else {
            print("❌ Failed to create audio format")
            return
        }
        
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        
        do {
            try engine.start()
            player.play()
            print("🔊 Audio engine started")
        } catch {
            print("❌ Failed to start audio engine: \(error)")
        }
    }
    
    private func processAudioData(_ data: Data) {
        // For now, we'll implement a basic PCM audio player
        // In a full implementation, you would decode AAC data here
        
        guard let format = audioFormat,
              let player = playerNode,
              let engine = audioEngine,
              engine.isRunning else {
            return
        }
        
        // Convert raw audio data to PCM buffer
        // This is a simplified implementation - real AAC decoding would be more complex
        let frameCount = AVAudioFrameCount(data.count / (Int(format.channelCount) * 2)) // 16-bit samples
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        
        buffer.frameLength = frameCount
        
        // Copy audio data to buffer (simplified - assumes PCM data)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: Int16.self).baseAddress else { return }
            
            for channel in 0..<Int(format.channelCount) {
                guard let channelData = buffer.int16ChannelData?[channel] else { continue }
                
                for frame in 0..<Int(frameCount) {
                    let sampleIndex = frame * Int(format.channelCount) + channel
                    if sampleIndex < bytes.count / 2 {
                        channelData[frame] = baseAddress[sampleIndex]
                    }
                }
            }
        }
        
        // Schedule buffer for playback
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
    
    func stop() {
        playerNode?.stop()
        audioEngine?.stop()
    }
    
    func pause() {
        playerNode?.pause()
    }
    
    func resume() {
        playerNode?.play()
    }
}