//
//  VideoDecoder.swift
//  SparkAirPlay
//
//  Created by Spark Liang on 28/07/2025.
//

import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia

/// Hardware-accelerated H.264 video decoder using VideoToolbox
class VideoDecoder {
    var outputLayer: AVSampleBufferDisplayLayer?
    
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let decoderQueue = DispatchQueue(label: "video.decoder.queue")
    
    init() {
        setupDecompressionSession()
    }
    
    deinit {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
    }
    
    func decodeFrame(data: Data) {
        decoderQueue.async { [weak self] in
            self?.processH264Data(data)
        }
    }
    
    private func setupDecompressionSession() {
        // Will be created when we receive the first SPS/PPS
        print("🎬 Video decoder initialized")
    }
    
    private func processH264Data(_ data: Data) {
        // Parse H.264 NAL units
        let nalUnits = parseNALUnits(from: data)
        
        for nalUnit in nalUnits {
            guard nalUnit.count > 0 else { continue }
            
            let nalType = nalUnit[0] & 0x1F
            
            switch nalType {
            case 7: // SPS (Sequence Parameter Set)
                handleSPS(nalUnit)
            case 8: // PPS (Picture Parameter Set)
                handlePPS(nalUnit)
            case 5: // IDR frame
                decodeVideoFrame(nalUnit, isKeyFrame: true)
            case 1: // Non-IDR frame
                decodeVideoFrame(nalUnit, isKeyFrame: false)
            default:
                print("🔍 Unknown NAL unit type: \(nalType)")
            }
        }
    }
    
    private func parseNALUnits(from data: Data) -> [Data] {
        var nalUnits: [Data] = []
        var currentIndex = 0
        
        while currentIndex < data.count - 4 {
            // Look for start code (0x00000001 or 0x000001)
            if data[currentIndex] == 0x00 && data[currentIndex + 1] == 0x00 {
                var startCodeLength = 0
                if data[currentIndex + 2] == 0x00 && data[currentIndex + 3] == 0x01 {
                    startCodeLength = 4
                } else if data[currentIndex + 2] == 0x01 {
                    startCodeLength = 3
                }
                
                if startCodeLength > 0 {
                    // Find next start code or end of data
                    let nalStart = currentIndex + startCodeLength
                    var nalEnd = data.count
                    
                    for i in (nalStart + 3)..<data.count - 3 {
                        if data[i] == 0x00 && data[i + 1] == 0x00 &&
                           (data[i + 2] == 0x01 || (data[i + 2] == 0x00 && data[i + 3] == 0x01)) {
                            nalEnd = i
                            break
                        }
                    }
                    
                    if nalEnd > nalStart {
                        let nalUnit = data.subdata(in: nalStart..<nalEnd)
                        nalUnits.append(nalUnit)
                    }
                    
                    currentIndex = nalEnd
                } else {
                    currentIndex += 1
                }
            } else {
                currentIndex += 1
            }
        }
        
        return nalUnits
    }
    
    private func handleSPS(_ spsData: Data) {
        print("📺 Received SPS data")
        createFormatDescription(sps: spsData, pps: nil)
    }
    
    private func handlePPS(_ ppsData: Data) {
        print("📺 Received PPS data")
        // PPS will be handled when creating format description
    }
    
    private func createFormatDescription(sps: Data, pps: Data?) {
        guard sps.count > 0 else { return }
        
        // Create parameter sets array
        let parameterSets = [sps]
        let parameterSetPointers = parameterSets.map { $0.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! } }
        let parameterSetSizes = parameterSets.map { $0.count }
        
        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: parameterSets.count,
            parameterSetPointers: parameterSetPointers,
            parameterSetSizes: parameterSetSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &formatDesc
        )
        
        if status == noErr, let formatDescription = formatDesc {
            self.formatDescription = formatDescription
            createDecompressionSession()
        } else {
            print("❌ Failed to create format description: \(status)")
        }
    }
    
    private func createDecompressionSession() {
        guard let formatDescription = formatDescription else { return }
        
        if let existingSession = decompressionSession {
            VTDecompressionSessionInvalidate(existingSession)
        }
        
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        
        if status == noErr {
            decompressionSession = newSession
            print("✅ Video decompression session created")
        } else {
            print("❌ Failed to create decompression session: \(status)")
        }
    }
    
    private func decodeVideoFrame(_ nalData: Data, isKeyFrame: Bool) {
        guard decompressionSession != nil,
              let formatDescription = formatDescription else {
            print("⚠️ Decompression session not ready")
            return
        }
        
        // Create sample buffer from NAL unit
        var sampleBuffer: CMSampleBuffer?
        
        // Convert NAL unit to AVCC format (length + data)
        var avccData = Data()
        var length = UInt32(nalData.count).bigEndian
        avccData.append(Data(bytes: &length, count: 4))
        avccData.append(nalData)
        
        var blockBuffer: CMBlockBuffer?
        let status1 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status1 == noErr, let blockBuffer = blockBuffer else {
            print("❌ Failed to create block buffer")
            return
        }
        
        let status2 = CMBlockBufferReplaceDataBytes(
            with: avccData.withUnsafeBytes { $0.bindMemory(to: UInt8.self).baseAddress! },
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: avccData.count
        )
        
        guard status2 == noErr else {
            print("❌ Failed to fill block buffer")
            return
        }
        
        // Create sample buffer
        let sampleSize = avccData.count
        let status3 = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [sampleSize],
            sampleBufferOut: &sampleBuffer
        )
        
        guard status3 == noErr, let sampleBuffer = sampleBuffer else {
            print("❌ Failed to create sample buffer")
            return
        }
        
        // Display the frame
        DispatchQueue.main.async { [weak self] in
            guard let layer = self?.outputLayer else { return }
            
            // Use the modern enqueue method
            layer.enqueue(sampleBuffer)
        }
    }
}