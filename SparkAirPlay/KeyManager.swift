//
//  KeyManager.swift
//  SparkAirPlay
//
//  Created by Spark Liang on 01/08/2025.
//

import Foundation
import CryptoKit
import SystemConfiguration
import Darwin

class KeyManager {
    static let shared = KeyManager()

    private init() {}

    func getDeviceID() -> String {
        // Try to get real MAC address first
        if let realMac = getRealMacAddress() {
            return realMac.replacingOccurrences(of: ":", with: "").lowercased()
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
        
        return macBytes.map { String(format: "%02X", $0) }.joined(separator: ":").replacingOccurrences(of: ":", with: "").lowercased()
    }

    func getInstanceID() -> String {
        let uuidStorageKey = "SparkAirPlay.PersistentInstanceID"
        if let existingUUID = UserDefaults.standard.string(forKey: uuidStorageKey) {
            return existingUUID
        }
        let newUUID = UUID().uuidString
        UserDefaults.standard.set(newUUID, forKey: uuidStorageKey)
        print("🆔 Generated new persistent instance ID: \(newUUID)")
        return newUUID
    }

    func getPublicKeyData() -> Data {
        let keyStorageKey = "SparkAirPlay.Curve25519.PublicKey"
        if let existingKeyHex = UserDefaults.standard.string(forKey: keyStorageKey) {
            return dataFromHex(existingKeyHex) ?? Data()
        }
        
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let publicKeyData = publicKey.rawRepresentation
        let publicKeyHex = publicKeyData.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(publicKeyHex, forKey: keyStorageKey)
        
        let privateKeyData = privateKey.rawRepresentation
        let privateKeyHex = privateKeyData.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(privateKeyHex, forKey: "SparkAirPlay.Curve25519.PrivateKey")
        
        print("🔐 Generated new Curve25519 key pair")
        print("🔑 Public key: \(publicKeyHex)")
        
        return publicKeyData
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

    private func dataFromHex(_ hex: String) -> Data? {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
            index = nextIndex
        }
        return data
    }
}
