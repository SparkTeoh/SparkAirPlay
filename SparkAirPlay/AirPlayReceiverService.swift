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
    private var currentServicePort: UInt16 = 7000
    
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
            self.currentServicePort = portToTry
            self.startBonjourAdvertisement(port: portToTry)
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
    
    private func startBonjourAdvertisement(port: UInt16) {
    let serviceName = getDeviceName()
    let raopName = "\(AirPlayConfiguration.deviceID)@\(serviceName)"

    // For the AirPlay service
    airplayService = NetService(domain: "", type: "_airplay._tcp.", name: serviceName, port: Int32(port))
    airplayService?.delegate = self
    let airPlayTXTData = NetService.data(fromTXTRecord: getAirPlayTXTRecord())
    airplayService?.setTXTRecord(airPlayTXTData)
    airplayService?.publish()

    // For the RAOP service
    raopService = NetService(domain: "", type: "_raop._tcp.", name: raopName, port: Int32(port))
    raopService?.delegate = self
    let raopTXTData = NetService.data(fromTXTRecord: getRAOPTXTRecord())
    raopService?.setTXTRecord(raopTXTData)
    raopService?.publish()
    
    print(" Starting Bonjour advertisement for '\(serviceName)' on port \(port)")
}

private func startBonjourAdvertisement(port: UInt16, retry: Bool) {
    if retry {
        // To avoid name conflicts, generate a random name
        let serviceName = "\(getDeviceName())-\(Int.random(in: 1000...9999))"
        let raopName = "\(AirPlayConfiguration.deviceID)@\(serviceName)"

        // For the AirPlay service
        airplayService = NetService(domain: "", type: "_airplay._tcp.", name: serviceName, port: Int32(port))
        airplayService?.delegate = self
        let airPlayTXTData = NetService.data(fromTXTRecord: getAirPlayTXTRecord())
        airplayService?.setTXTRecord(airPlayTXTData)
        airplayService?.publish()

        // For the RAOP service
        raopService = NetService(domain: "", type: "_raop._tcp.", name: raopName, port: Int32(port))
        raopService?.delegate = self
        let raopTXTData = NetService.data(fromTXTRecord: getRAOPTXTRecord())
        raopService?.setTXTRecord(raopTXTData)
        raopService?.publish()
        
        print(" Starting Bonjour advertisement for '\(serviceName)' on port \(port)")
    } else {
        startBonjourAdvertisement(port: port)
    }
}
    
    private func getAirPlayTXTRecord() -> [String: Data] {
        return [
            "deviceid": AirPlayConfiguration.deviceID.data(using: .utf8)!,
            "features": String(AirPlayConfiguration.features).data(using: .utf8)!,
            "model": AirPlayConfiguration.model.data(using: .utf8)!,
            "srcvers": AirPlayConfiguration.sourceVersion.data(using: .utf8)!,
            "vv": String(AirPlayConfiguration.vv).data(using: .utf8)!
        ]
    }

    private func getRAOPTXTRecord() -> [String: Data] {
        return [
            "txtvers": "1".data(using: .utf8)!,
            "ch": "2".data(using: .utf8)!,
            "cn": "0,1,2,3".data(using: .utf8)!,
            "da": "true".data(using: .utf8)!,
            "et": "0,3,5".data(using: .utf8)!,
            "ft": String(AirPlayConfiguration.features).data(using: .utf8)!,
            "md": "0,1,2".data(using: .utf8)!,
            "pw": "false".data(using: .utf8)!,
            "sr": "44100".data(using: .utf8)!,
            "ss": "16".data(using: .utf8)!,
            "tp": "UDP".data(using: .utf8)!,
            "vn": "65537".data(using: .utf8)!,
            "vs": AirPlayConfiguration.sourceVersion.data(using: .utf8)!,
            "am": AirPlayConfiguration.model.data(using: .utf8)!,
            "sf": String(AirPlayConfiguration.statusFlags).data(using: .utf8)!
        ]
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
                self.startBonjourAdvertisement(port: self.currentServicePort, retry: true)
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