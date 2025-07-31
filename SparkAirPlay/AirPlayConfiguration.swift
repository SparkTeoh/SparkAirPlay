//
//  AirPlayConfiguration.swift
//  SparkAirPlay
//
//  Created by Spark Liang on 01/08/2025.
//

import Foundation

struct AirPlayConfiguration {
    static let deviceID = KeyManager.shared.getDeviceID()
    static let features: UInt64 = 119
    static let model = "AppleTV3,2"
    static let persistentID = KeyManager.shared.getInstanceID()
    static let protocolVersion = "1.0"
    static let sourceVersion = "379.27.1"
    static let vv: UInt64 = 2
    static let statusFlags: UInt64 = 4
}
