//
//  RTSPServer.swift
//  SparkAirPlay
//
//  Created by Spark Liang on 28/07/2025.
//

import Foundation
import Network
import SystemConfiguration
import Darwin
import CryptoKit

protocol RTSPServerDelegate: AnyObject {
    func rtspServerDidAcceptConnection(from address: String)
    func rtspServerDidDisconnect()
    func rtspServerDidReceiveVideoData(_ data: Data)
    func rtspServerDidEncounterError(_ error: Error)
}

/// RTSP server implementation for handling AirPlay streaming protocol
class RTSPServer {
    weak var delegate: RTSPServerDelegate?
    
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "rtsp.server.queue", qos: .userInitiated)
    
    private var sessionId: String?
    private var isStreaming = false
    
    init(port: UInt16) {
        self.port = port
    }
    
    func start() -> Bool {
        // Stop any existing listener first
        stop()
        
        var success = false
        let semaphore = DispatchSemaphore(value: 0)
        
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.allowFastOpen = false  // Disable for better compatibility
            parameters.includePeerToPeer = true
            
            // Configure for both IPv4 and IPv6 support
            parameters.acceptLocalOnly = false
            parameters.preferNoProxies = true
            
            // Set required interfaces - allow all network interfaces
            parameters.requiredInterfaceType = .other
            parameters.prohibitedInterfaceTypes = []
            
            // Configure TCP options for better connection stability
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 30  // Start keepalive after 30 seconds
            tcpOptions.keepaliveInterval = 10  // Send keepalive every 10 seconds
            tcpOptions.keepaliveCount = 3  // Allow 3 failed keepalives before closing
            tcpOptions.noDelay = true  // Disable Nagle's algorithm for lower latency
            parameters.defaultProtocolStack.transportProtocol = tcpOptions
            
            // Create listener that binds to all interfaces (IPv4 and IPv6)
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("🎯 RTSP Server listening on port \(self?.port ?? 0)")
                    success = true
                    semaphore.signal()
                case .failed(let error):
                    print("❌ RTSP Server failed on port \(self?.port ?? 0): \(error)")
                    success = false
                    semaphore.signal()
                case .cancelled:
                    print("🛑 RTSP Server cancelled")
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            
            listener?.start(queue: queue)
            
            // Wait for the listener to start or fail (with timeout)
            let result = semaphore.wait(timeout: .now() + 2.0)
            if result == .timedOut {
                print("⏰ RTSP Server start timeout on port \(port)")
                stop()
                return false
            }
            
            return success
            
        } catch {
            print("❌ Failed to create RTSP server on port \(port): \(error)")
            return false
        }
    }
    
    func stop() {
        listener?.cancel()
        rtpListener?.cancel()
        rtcpListener?.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isStreaming = false
    }
    
    func disconnectAllClients() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isStreaming = false
        delegate?.rtspServerDidDisconnect()
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let address = extractAddress(from: connection.endpoint)
        print("🔗 Accepting new connection from: \(address)")
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            print("[DEBUG] Connection state for \(address): \(state)")
            switch state {
            case .ready:
                print("✅ RTSP connection ready from: \(address)")
                // Don't notify connection until we start streaming
                self?.startReceiving(on: connection)
            case .cancelled:
                print("🛑 RTSP connection cancelled from: \(address)")
                self?.removeConnection(connection)
            case .failed(let error):
                print("❌ RTSP connection failed from: \(address), error: \(error)")
                print("   Error details: \(error)")
                print("   NWError type: \(type(of: error))")
                self?.removeConnection(connection)
            case .waiting(let error):
                print("⏳ RTSP connection waiting from: \(address), error: \(error)")
            case .preparing:
                print("🔄 RTSP connection preparing from: \(address)")
            case .setup:
                print("🔧 RTSP connection setup from: \(address)")
            @unknown default:
                print("❓ RTSP connection unknown state from: \(address): \(state)")
            }
        }
        connection.start(queue: queue)
    }
    
    private func startReceiving(on connection: NWConnection) {
        let address = extractAddress(from: connection.endpoint)
        print("🔄 Starting to receive data from \(address)")
        
        // Don't set aggressive timeout - let AirPlay handshake complete naturally
        receiveData(on: connection)
    }
    
    private func receiveData(on connection: NWConnection) {
        let address = extractAddress(from: connection.endpoint)
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let error = error {
                print("❌ Receive error from \(address): \(error)")
                // Check if it's a connection error
                if let nwError = error as? NWError {
                    switch nwError {
                    case .posix(let posixError):
                        switch posixError {
                        case .ECONNRESET, .ENOTCONN, .EPIPE:
                            print("🔌 Connection lost from \(address), removing")
                            self?.removeConnection(connection)
                        default:
                            print("⚠️ Non-critical error from \(address), continuing: \(posixError)")
                            // Continue receiving for non-critical errors
                            self?.receiveData(on: connection)
                        }
                    default:
                        print("🔌 Network error from \(address), removing connection")
                        self?.removeConnection(connection)
                    }
                } else {
                    print("🔌 Unknown error from \(address), removing connection")
                    self?.removeConnection(connection)
                }
                return
            }
            
            if let data = data, !data.isEmpty {
                self?.processRTSPData(data, from: connection)
            }
            
            if isComplete {
                print("📡 Connection end-of-stream from \(address)")
                self?.removeConnection(connection)
            } else {
                // Continue receiving more RTSP requests
                self?.receiveData(on: connection)
            }
        }
    }
    
    private func processRTSPData(_ data: Data, from connection: NWConnection) {
        let address = extractAddress(from: connection.endpoint)
        print("📥 Received \(data.count) bytes from \(address)")

        // Find end of headers (\r\n\r\n)
        guard let headerEndRange = data.range(of: Data([13,10,13,10])) else {
            print("❌ Incomplete RTSP headers from \(address)")
            return
        }

        let headerData = data.subdata(in: 0..<headerEndRange.lowerBound)
        let bodyData = data.subdata(in: headerEndRange.upperBound..<data.count)

        // Parse headers as UTF-8
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            print("❌ Invalid RTSP header encoding from \(address)")
            return
        }

        print("🔎 RTSP headers:\n\(headerString)")
        if !bodyData.isEmpty {
            print("🔎 RTSP body: \(bodyData.count) bytes")
        }

        // Parse the request
        let (method, url, version, cseq, headers) = parseRTSPMessage(headerString)
        
        print("🔍 Parsed: \(method) \(url) (CSeq: \(cseq))")
        
        // Process the RTSP request
        processRTSPMessage(method: method, url: url, version: version, cseq: cseq, headers: headers, body: bodyData, from: connection)
    }
    
    private func processRTSPMessage(method: String, url: String, version: String, cseq: String, headers: [String: String], body: Data, from connection: NWConnection) {
        let address = extractAddress(from: connection.endpoint)
        print("🎯 Processing RTSP request from \(address):")
        print("   Method: \(method)")
        print("   URL: \(url)")
        print("   CSeq: \(cseq)")
        print("   Headers: \(headers.count) items")
        
        // Log important headers
        if let userAgent = headers["user-agent"] {
            print("   User-Agent: \(userAgent)")
        }
        if let contentLength = headers["content-length"] {
            print("   Content-Length: \(contentLength)")
        }
        if let transport = headers["transport"] {
            print("   Transport: \(transport)")
        }
        if let session = headers["session"] {
            print("   Session: \(session)")
        }
        
        // Log all headers for debugging
        print("   All headers:")
        for (key, value) in headers {
            print("     \(key): \(value)")
        }
        
        if method == "GET" && url == "/info" {
            print("✅ Handling GET /info request")
            
            // Parse iPhone's device info if present in body
            if !body.isEmpty {
                print("📱 iPhone sent device info: \(body.count) bytes")
                if let plist = try? PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any] {
                    print("📱 iPhone device info: \(plist)")
                } else {
                    print("📱 Could not parse iPhone device info as plist")
                }
            }
            
            sendInfoResponse(to: connection, cseq: cseq)
        } else if method == "POST" && url == "/feedback" {
            print("✅ Handling POST /feedback request")
            sendFeedbackResponse(to: connection, cseq: cseq)
        } else {
            switch method {
            case "OPTIONS":
                print("✅ Handling OPTIONS request")
                sendOptionsResponse(to: connection, cseq: cseq)
            case "ANNOUNCE":
                print("✅ Handling ANNOUNCE request")
                let message = headers.map { "\($0): \($1)" }.joined(separator: "\n") + "\n\n" + (String(data: body, encoding: .utf8) ?? "")
                sendAnnounceResponse(to: connection, cseq: cseq, message: message)
            case "SETUP":
                print("✅ Handling SETUP request")
                sendSetupResponse(to: connection, cseq: cseq, headers: headers)
            case "RECORD":
                print("✅ Handling RECORD request")
                sendRecordResponse(to: connection, cseq: cseq)
                isStreaming = true
                // Now we're actually streaming, notify connection
                let address = extractAddress(from: connection.endpoint)
                delegate?.rtspServerDidAcceptConnection(from: address)
            case "TEARDOWN":
                print("✅ Handling TEARDOWN request")
                sendTeardownResponse(to: connection, cseq: cseq)
                isStreaming = false
            case "GET_PARAMETER":
                print("✅ Handling GET_PARAMETER request")
                sendGetParameterResponse(to: connection, cseq: cseq)
            case "SET_PARAMETER":
                print("✅ Handling SET_PARAMETER request")
                sendSetParameterResponse(to: connection, cseq: cseq)
            default:
                print("❌ Unknown RTSP method: \(method)")
                // Send a generic error response
                let response = "RTSP/1.0 501 Not Implemented\r\nCSeq: \(cseq)\r\n\r\n"
                if let responseData = response.data(using: .utf8) {
                    connection.send(content: responseData, completion: .contentProcessed { error in
                        if let error = error {
                            print("❌ Failed to send error response: \(error)")
                        }
                    })
                }
            }
        }
    }
    
    private func parseRTSPMessage(_ headerString: String) -> (method: String, url: String, version: String, cseq: String, headers: [String: String]) {
        // RTSP uses \r\n line endings, so split properly and trim whitespace
        let lines = headerString.components(separatedBy: "\r\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let requestLine = lines.first, !requestLine.isEmpty else { return ("", "", "", "", [:]) }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 3 else { return ("", "", "", "", [:]) }
        let method = components[0]
        let url = components[1]
        let version = components[2]
        
        var headers: [String: String] = [:]
        var cseq = ""
        
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            
            // Look for the first colon to separate header name and value
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                
                if !key.isEmpty && !value.isEmpty {
                    headers[key] = value
                    if key == "cseq" { cseq = value }
                }
            }
        }
        return (method, url, version, cseq, headers)
    }
    
    private func sendOptionsResponse(to connection: NWConnection, cseq: String) {
        let response = """
        RTSP/1.0 200 OK
        CSeq: \(cseq)
        Public: ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER
        Server: SparkAirPlay/1.0
        
        """
        sendResponse(response, to: connection)
    }
    
    private func sendAnnounceResponse(to connection: NWConnection, cseq: String, message: String) {
        let response = """
        RTSP/1.0 200 OK
        CSeq: \(cseq)
        Server: SparkAirPlay/1.0
        
        """
        sendResponse(response, to: connection)
    }
    
    private func sendGetParameterResponse(to connection: NWConnection, cseq: String) {
        let response = """
        RTSP/1.0 200 OK
        CSeq: \(cseq)
        Server: SparkAirPlay/1.0
        
        """
        sendResponse(response, to: connection)
    }
    
    private func sendSetParameterResponse(to connection: NWConnection, cseq: String) {
        let response = """
        RTSP/1.0 200 OK
        CSeq: \(cseq)
        Server: SparkAirPlay/1.0
        
        """
        sendResponse(response, to: connection)
    }
    
    private func sendRecordResponse(to connection: NWConnection, cseq: String) {
        let response = """
        RTSP/1.0 200 OK
        CSeq: \(cseq)
        Server: SparkAirPlay/1.0
        
        """
        sendResponse(response, to: connection)
    }
    
    private func sendTeardownResponse(to connection: NWConnection, cseq: String) {
        let response = """
        RTSP/1.0 200 OK
        CSeq: \(cseq)
        Server: SparkAirPlay/1.0
        
        """
        sendResponse(response, to: connection)
    }
    
    private func sendInfoResponse(to connection: NWConnection, cseq: String) {
        // Generate persistent device credentials
        let deviceId = getMacAddress().replacingOccurrences(of: ":", with: "").lowercased()
        let publicKeyHex = getPersistentPublicKey()
        let persistentID = getPersistentUUID()
        
        // Create the XML plist dictionary with proper AirPlay capabilities
        let plistDict: [String: Any] = [
            "deviceid": deviceId,
            "features": 119,                    // 0x77 - Basic video, photo, and audio streaming
            "model": "AppleTV3,2",             // Apple TV 3rd generation model
            "pk": publicKeyHex,                // Curve25519 public key (hex string)
            "pi": persistentID,                // Persistent instance UUID
            "vv": 2,                          // Video version
            "srcvers": "379.27.1"             // Source version
        ]
        
        do {
            // Serialize to XML plist format (not binary)
            let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            
            // Create RTSP response with correct headers
            let response = """
            RTSP/1.0 200 OK\r
            CSeq: \(cseq)\r
            Content-Type: text/x-apple-plist+xml\r
            Content-Length: \(plistData.count)\r
            Server: AirTunes/379.27.1\r
            \r
            """
            
            guard let responseData = response.data(using: .utf8) else {
                print("❌ Failed to encode info response headers")
                return
            }
            
            // Combine headers and plist data
            let fullResponse = responseData + plistData
            
            connection.send(content: fullResponse, completion: .contentProcessed { error in
                if let error = error {
                    print("❌ Failed to send /info response: \(error)")
                } else {
                    print("✅ Sent /info XML plist response successfully (\(plistData.count) bytes)")
                    if let plistString = String(data: plistData, encoding: .utf8) {
                        print("📄 Plist content preview:\n\(String(plistString.prefix(200)))...")
                    }
                }
            })
            
        } catch {
            print("❌ Failed to create XML plist: \(error)")
        }
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
    
    private func sendFeedbackResponse(to connection: NWConnection, cseq: String) {
        let response = """
        RTSP/1.0 200 OK
        CSeq: \(cseq)
        Server: SparkAirPlay/1.0
        
        """
        sendResponse(response, to: connection)
    }
    
    private var rtpListener: NWListener?
    private var rtcpListener: NWListener?
    
    private func sendSetupResponse(to connection: NWConnection, cseq: String, headers: [String: String]) {
        sessionId = UUID().uuidString
        
        // Parse client's transport
        let transport = headers["transport"] ?? ""
        var clientPorts = "0-1"
        if let range = transport.range(of: "client_port=") {
            let portStr = String(transport[range.upperBound...])
            clientPorts = portStr.components(separatedBy: ";")[0]
        }
        
        // Choose available server ports (for simplicity, using fixed; ideally find available)
        let serverRTPPort: UInt16 = 6002
        let serverRTCPPort: UInt16 = 6003
        
        let responseTransport = "RTP/AVP/UDP;unicast;client_port=\(clientPorts);server_port=\(serverRTPPort)-\(serverRTCPPort)"
        
        let response = """
        RTSP/1.0 200 OK
        CSeq: \(cseq)
        Server: SparkAirPlay/1.0
        Session: \(sessionId!)
        Transport: \(responseTransport)
        
        """
        sendResponse(response, to: connection)
        
        // Set up UDP listeners
        setupUDPlisteners(rtpPort: serverRTPPort, rtcpPort: serverRTCPPort)
    }
    
    private func setupUDPlisteners(rtpPort: UInt16, rtcpPort: UInt16) {
        do {
            let udpParams = NWParameters.udp
            udpParams.allowLocalEndpointReuse = true
            
            rtpListener = try NWListener(using: udpParams, on: NWEndpoint.Port(rawValue: rtpPort)!)
            rtpListener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("🎥 RTP listener ready on port \(rtpPort)")
                case .failed(let error):
                    print("❌ RTP listener failed: \(error)")
                default:
                    break
                }
            }
            rtpListener?.newConnectionHandler = { [weak self] connection in
                self?.handleUDPConnection(connection, isRTP: true)
            }
            rtpListener?.start(queue: queue)
            
            rtcpListener = try NWListener(using: udpParams, on: NWEndpoint.Port(rawValue: rtcpPort)!)
            rtcpListener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("🎥 RTCP listener ready on port \(rtcpPort)")
                case .failed(let error):
                    print("❌ RTCP listener failed: \(error)")
                default:
                    break
                }
            }
            rtcpListener?.newConnectionHandler = { [weak self] connection in
                self?.handleUDPConnection(connection, isRTP: false)
            }
            rtcpListener?.start(queue: queue)
            
            print("🎥 UDP listeners started on ports \(rtpPort) (RTP) and \(rtcpPort) (RTCP)")
        } catch {
            print("❌ Failed to start UDP listeners: \(error)")
        }
    }
    
    private func handleUDPConnection(_ connection: NWConnection, isRTP: Bool) {
        connection.start(queue: queue)
        startUDPReceiving(on: connection, isRTP: isRTP)
    }
    
    private func startUDPReceiving(on connection: NWConnection, isRTP: Bool) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            if let error = error {
                print("❌ UDP receive error: \(error)")
                return
            }
            
            if let data = data, !data.isEmpty {
                if isRTP {
                    self?.processRTPPacket(data)
                } else {
                    // Handle RTCP packets if needed
                    print("📊 Received RTCP packet")
                }
            }
            
            if !isComplete {
                self?.startUDPReceiving(on: connection, isRTP: isRTP)
            }
        }
    }
    
    private func processRTPPacket(_ data: Data) {
        delegate?.rtspServerDidReceiveVideoData(data)
    }
    
    private func sendResponse(_ response: String, to connection: NWConnection) {
        let address = extractAddress(from: connection.endpoint)
        print("📤 Sending RTSP response to \(address):")
        print("   Response: \(response.components(separatedBy: "\r\n").first ?? "Unknown")")
        
        guard let data = response.data(using: .utf8) else {
            print("❌ Failed to encode response data")
            return
        }
        
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Failed to send RTSP response to \(address): \(error)")
                // Check if it's a connection error
                if let nwError = error as? NWError {
                    switch nwError {
                    case .posix(let posixError):
                        switch posixError {
                        case .ECONNRESET, .ENOTCONN, .EPIPE:
                            print("🔌 Connection lost while sending response to \(address)")
                            self.removeConnection(connection)
                        default:
                            print("⚠️ Non-critical send error to \(address): \(posixError)")
                        }
                    default:
                        print("🔌 Network error while sending response to \(address)")
                        self.removeConnection(connection)
                    }
                }
            } else {
                print("✅ Successfully sent RTSP response to \(address)")
            }
        })
    }
    
    private func extractAddress(from endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return "Unknown"
        }
    }
    
    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        // Only notify disconnection if we were actually streaming
        // Don't restart service for simple probe connections like /info requests
        if connections.isEmpty && isStreaming {
            print("📡 Last streaming connection closed")
            delegate?.rtspServerDidDisconnect()
            isStreaming = false
        } else if connections.isEmpty {
            print("📡 Probe connection closed, keeping service running")
        }
    }
    
    // MARK: - Persistent Crypto Keys and UUID
    
    private func getPersistentPublicKey() -> String {
        let keyStorageKey = "SparkAirPlay.Curve25519.PublicKey"
        
        // Try to load existing key from UserDefaults
        if let existingKey = UserDefaults.standard.string(forKey: keyStorageKey) {
            return existingKey
        }
        
        // Generate new Curve25519 key pair
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        // Convert public key to hex string
        let publicKeyData = publicKey.rawRepresentation
        let publicKeyHex = publicKeyData.map { String(format: "%02x", $0) }.joined()
        
        // Store the public key for future use
        UserDefaults.standard.set(publicKeyHex, forKey: keyStorageKey)
        
        // Also store the private key for potential future use (encrypted in real implementation)
        let privateKeyData = privateKey.rawRepresentation
        let privateKeyHex = privateKeyData.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(privateKeyHex, forKey: "SparkAirPlay.Curve25519.PrivateKey")
        
        print("🔐 Generated new Curve25519 key pair")
        print("🔑 Public key: \(publicKeyHex)")
        
        return publicKeyHex
    }
    
    private func getPersistentUUID() -> String {
        let uuidStorageKey = "SparkAirPlay.PersistentInstanceID"
        
        // Try to load existing UUID from UserDefaults
        if let existingUUID = UserDefaults.standard.string(forKey: uuidStorageKey) {
            return existingUUID
        }
        
        // Generate new UUID
        let newUUID = UUID().uuidString
        
        // Store for future use
        UserDefaults.standard.set(newUUID, forKey: uuidStorageKey)
        
        print("🆔 Generated new persistent instance ID: \(newUUID)")
        
        return newUUID
    }
}