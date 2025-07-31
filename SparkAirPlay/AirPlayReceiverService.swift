//
//  AirPlayReceiverService.swift
//  SparkAirPlay
//
//  Created by Spark Liang on 28/07/2025.
//

import Foundation
import Network
import SystemConfiguration
import AVFoundation
import Darwin

protocol AirPlayReceiverDelegate: AnyObject {
    func airPlayDidConnect(from device: String)
    func airPlayDidDisconnect()
    func airPlayDidReceiveVideo(data: Data)
    func airPlayDidReceiveError(_ error: Error)
}

/// Core AirPlay receiver service that handles Bonjour discovery and RTSP/RTP streams
class AirPlayReceiverService: NSObject {
    static let shared = AirPlayReceiverService()
    
    weak var delegate: AirPlayReceiverDelegate?
    
    private var airplayService: NetService?
    private var raopService: NetService?
    private var rtspServer: RTSPServer?
    private var isServiceRunning = false
    private let servicePort: UInt16 = 7000
    private var actualRtspPort: UInt16? = nil
    
    private override init() {
        super.init()
    }
    
    func startService() {
        stopService()
        
        print("🔍 Starting AirPlay service...")
        
        // Start immediately without delay
        performStartService()
    }
    
    private func performStartService() {
        guard !isServiceRunning else { return }
        
        var portToTry = servicePort
        var serverStarted = false
        
        for attempt in 0..<10 {
            print("🔄 Attempting to start RTSP server on port \(portToTry) (attempt \(attempt + 1)/10)")
            
            rtspServer = RTSPServer(port: portToTry)
            rtspServer?.delegate = self
            
            if rtspServer?.start() == true {
                serverStarted = true
                actualRtspPort = portToTry
                print("✅ RTSP Server started successfully on port \(portToTry)")
                break
            } else {
                print("❌ Port \(portToTry) failed, trying next port...")
                rtspServer?.stop()
                rtspServer = nil
                portToTry += 1
                // Longer delay between attempts
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        
        guard serverStarted else {
            print("❌ Failed to start RTSP server on any port")
            return
        }
        
        // Small delay before starting Bonjour advertisement
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.startBonjourAdvertisement()
        }
        
        isServiceRunning = true
        print("🚀 AirPlay service started successfully on port \(portToTry)")
    }
    
    func stopService() {
        guard isServiceRunning else { return }
        
        stopBonjourAdvertisement()
        stopRTSPServer()
        
        isServiceRunning = false
        print("🛑 AirPlay receiver service stopped")
    }
    
    private func stopBonjourAdvertisement() {
        airplayService?.stop()
        airplayService = nil
        raopService?.stop()
        raopService = nil
        print("🛑 Stopped Bonjour advertisement")
    }
    
    func disconnectCurrentClient() {
        rtspServer?.disconnectAllClients()
    }
    
    // MARK: - Bonjour Advertisement
    
    private func startBonjourAdvertisement(retry: Bool = false) {
        guard let actualPort = actualRtspPort else {
            print("❌ Cannot start Bonjour advertisement: RTSP port not available")
            return
        }
        
        let deviceName = getAirPlayName()
        let serviceName = retry ? "\(deviceName)-\(Int.random(in: 1000...9999))" : deviceName
        
        print("🔄 Starting Bonjour advertisement for '\(serviceName)' on port \(actualPort)")
        
        // Publish AirPlay service
        airplayService = NetService(domain: "", type: "_airplay._tcp.", name: serviceName, port: Int32(actualPort))
        airplayService?.delegate = self
        
        let txtData = createAirPlayTXTRecord()
        airplayService?.setTXTRecord(txtData)
        airplayService?.publish()
        
        // Also publish RAOP service for better compatibility
        let raopName = "\(getMacAddress().replacingOccurrences(of: ":", with: "").lowercased())@\(serviceName)"
        raopService = NetService(domain: "", type: "_raop._tcp.", name: raopName, port: Int32(actualPort))
        raopService?.delegate = self
        
        let raopTxtData = createRAOPTXTRecord()
        raopService?.setTXTRecord(raopTxtData)
        raopService?.publish()
        
        print("📡 Published AirPlay service: \(serviceName)")
        print("📡 Published RAOP service: \(raopName)")
    }
    
    private func createAirPlayTXTRecord() -> Data {
        // Only include PUBLIC discovery information in Bonjour TXT record
        // DO NOT include pk (public key) or pi (instance ID) here - they are private!
        let txtRecord: [String: Data] = [
            "deviceid": getMacAddress().replacingOccurrences(of: ":", with: "").lowercased().data(using: .utf8) ?? Data(),
            "features": "0x5A7FFFF7,0x1E".data(using: .utf8) ?? Data(),    // Full AirPlay capabilities
            "flags": "0x4".data(using: .utf8) ?? Data(),
            "model": "AppleTV6,2".data(using: .utf8) ?? Data(),
            "protovers": "1.1".data(using: .utf8) ?? Data(),
            "srcvers": "379.27.1".data(using: .utf8) ?? Data(),
            "vv": "2".data(using: .utf8) ?? Data(),
            "pw": "false".data(using: .utf8) ?? Data()
        ]
        return NetService.data(fromTXTRecord: txtRecord)
    }
    
    private func createRAOPTXTRecord() -> Data {
        let txtRecord: [String: Data] = [
            "txtvers": "1".data(using: .utf8) ?? Data(),
            "ch": "2".data(using: .utf8) ?? Data(),
            "cn": "0,1,2,3".data(using: .utf8) ?? Data(),
            "da": "true".data(using: .utf8) ?? Data(),
            "et": "0,3,5".data(using: .utf8) ?? Data(),
            "ft": "0x5A7FFFF7,0x1E".data(using: .utf8) ?? Data(),
            "md": "0,1,2".data(using: .utf8) ?? Data(),
            "pw": "false".data(using: .utf8) ?? Data(),
            "sr": "44100".data(using: .utf8) ?? Data(),
            "ss": "16".data(using: .utf8) ?? Data(),
            "tp": "UDP".data(using: .utf8) ?? Data(),
            "vn": "65537".data(using: .utf8) ?? Data(),
            "vs": "379.27.1".data(using: .utf8) ?? Data(),
            "am": "AppleTV6,2".data(using: .utf8) ?? Data(),
            "sf": "0x4".data(using: .utf8) ?? Data()
        ]
        return NetService.data(fromTXTRecord: txtRecord)
    }
    
    private func getDeviceName() -> String {
        return Host.current().localizedName ?? "SparkAirPlay"
    }
    
    private func getAirPlayName() -> String {
        return "SparkAirPlay"
    }
    
    private func getMacAddress() -> String {
        // Try to get real MAC address first
        if let realMac = getRealMacAddress() {
            return realMac
        }
        
        // Fallback to generated MAC address
        let deviceName = Host.current().localizedName ?? "Mac"
        let hash = abs(deviceName.hashValue)
        let macBytes = [
            0x02, // Set locally administered bit
            UInt8((hash >> 24) & 0xFF),
            UInt8((hash >> 16) & 0xFF),
            UInt8((hash >> 8) & 0xFF),
            UInt8(hash & 0xFF),
            UInt8(Int.random(in: 0...255))
        ]
        
        return macBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    
    private func getRealMacAddress() -> String? {
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0 else { return nil }
        defer { freeifaddrs(ifaddrs) }
        
        var ptr = ifaddrs
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            
            guard let interface = ptr?.pointee else { continue }
            let name = String(cString: interface.ifa_name)
            
            // Look for en0 (primary ethernet/wifi interface)
            if name == "en0" && interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) {
                let sockaddr = interface.ifa_addr!.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                let macData = withUnsafePointer(to: sockaddr.sdl_data) {
                    $0.withMemoryRebound(to: UInt8.self, capacity: Int(sockaddr.sdl_alen)) {
                        Array(UnsafeBufferPointer(start: $0.advanced(by: Int(sockaddr.sdl_nlen)), count: Int(sockaddr.sdl_alen)))
                    }
                }
                
                if macData.count == 6 {
                    return macData.map { String(format: "%02X", $0) }.joined(separator: ":")
                }
            }
        }
        return nil
    }
    
    // MARK: - RTSP Server
    
    private func stopRTSPServer() {
        rtspServer?.stop()
        rtspServer = nil
    }
}

// MARK: - NetServiceDelegate

extension AirPlayReceiverService: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        print("✅ Bonjour service successfully published: \(sender.name) (\(sender.type))")
        print("📡 Service details:")
        print("   - Name: \(sender.name)")
        print("   - Type: \(sender.type)")
        print("   - Domain: \(sender.domain)")
        print("   - Port: \(sender.port)")
    }
    
    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        print("❌ Failed to publish service '\(sender.name)' of type '\(sender.type)': \(errorDict)")
        
        // Check if it's a name collision error
        if let errorCode = errorDict[NetService.errorCode],
           errorCode.intValue == NetService.ErrorCode.collisionError.rawValue {
            print("🔄 Name collision detected, retrying with different name...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startBonjourAdvertisement(retry: true)
            }
        } else {
            print("❌ Unrecoverable Bonjour error, stopping service")
            stopService()
        }
    }
    
    func netServiceDidStop(_ sender: NetService) {
        print("🛑 Bonjour service stopped: \(sender.name)")
    }
}

// MARK: - RTSPServerDelegate
extension AirPlayReceiverService: RTSPServerDelegate {
    func rtspServerDidAcceptConnection(from address: String) {
        delegate?.airPlayDidConnect(from: address)
    }
    
    func rtspServerDidDisconnect() {
        delegate?.airPlayDidDisconnect()
    }
    
    func rtspServerDidReceiveVideoData(_ data: Data) {
        delegate?.airPlayDidReceiveVideo(data: data)
    }
    
    func rtspServerDidEncounterError(_ error: Error) {
        delegate?.airPlayDidReceiveError(error)
    }
}