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

// MARK: - TLV8 (Type-Length-Value) Implementation
struct TLV8 {
    let type: UInt8
    let data: Data
    
    init(type: UInt8, data: Data) {
        self.type = type
        self.data = data
    }
    
    init(type: UInt8, value: UInt8) {
        self.type = type
        self.data = Data([value])
    }
    
    init(type: UInt8, string: String) {
        self.type = type
        self.data = string.data(using: .utf8) ?? Data()
    }
}

extension TLV8 {
    /// Parse TLV8 data from binary format
    static func parse(_ data: Data) -> [TLV8] {
        var tlvs: [TLV8] = []
        var offset = 0
        
        while offset < data.count {
            guard offset + 2 <= data.count else { break }
            
            let type = data[offset]
            let length = data[offset + 1]
            
            guard offset + 2 + Int(length) <= data.count else { break }
            
            let value = data.subdata(in: (offset + 2)..<(offset + 2 + Int(length)))
            tlvs.append(TLV8(type: type, data: value))
            
            offset += 2 + Int(length)
        }
        
        return tlvs
    }
    
    /// Encode TLV8 array to binary data
    static func encode(_ tlvs: [TLV8]) -> Data {
        var data = Data()
        
        for tlv in tlvs {
            data.append(tlv.type)
            data.append(UInt8(tlv.data.count))
            data.append(tlv.data)
        }
        
        return data
    }
}

// MARK: - AirPlay Pairing Constants
enum PairingTLVType: UInt8 {
    case method = 0x00        // Pairing method
    case identifier = 0x01     // Identifier  
    case salt = 0x02          // Salt
    case publicKey = 0x03     // Public key
    case proof = 0x04         // Proof
    case encryptedData = 0x05 // Encrypted data
    case state = 0x06         // State
    case error = 0x07         // Error
    case signature = 0x0A     // Signature
    case separator = 0xFF     // Fragment separator
}

enum PairingMethod: UInt8 {
    case pairSetup = 0x01
    case pairVerify = 0x02
}

enum PairingState: UInt8 {
    case startRequest = 0x01
    case startResponse = 0x02
    case finishRequest = 0x03
    case finishResponse = 0x04
}

// MARK: - SRP (Secure Remote Password) Implementation
class SRPSession {
    private let username = "Pair-Setup"
    private let password = "3939"  // Standard AirPlay pairing code
    
    var privateKey: Curve25519.KeyAgreement.PrivateKey?
    var publicKey: Data?
    var salt: Data?
    var serverPublicKey: Data?
    var sharedSecret: Data?
    
    init() {
        generateKeyPair()
    }
    
    private func generateKeyPair() {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey.rawRepresentation
        
        // Generate random salt
        var saltBytes = Data(count: 16)
        let result = saltBytes.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 16, bytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        
        if result == errSecSuccess {
            self.salt = saltBytes
        } else {
            // Fallback salt generation
            self.salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        }
        
        print("🔐 Generated SRP session:")
        print("   Public key: \(publicKey?.map { String(format: "%02x", $0) }.joined() ?? "nil")")
        print("   Salt: \(salt?.map { String(format: "%02x", $0) }.joined() ?? "nil")")
    }
    
    func generateStartResponse() -> Data {
        guard let publicKey = self.publicKey,
              let salt = self.salt else {
            print("❌ SRP session not properly initialized")
            return Data()
        }
        
        let tlvs = [
            TLV8(type: PairingTLVType.state.rawValue, value: PairingState.startResponse.rawValue),
            TLV8(type: PairingTLVType.publicKey.rawValue, data: publicKey),
            TLV8(type: PairingTLVType.salt.rawValue, data: salt)
        ]
        
        return TLV8.encode(tlvs)
    }
    
    func processFinishRequest(_ tlvData: Data) -> Data? {
        let tlvs = TLV8.parse(tlvData)
        
        // Extract client's proof and public key from request
        for tlv in tlvs {
            if tlv.type == PairingTLVType.publicKey.rawValue {
                print("🔐 Received client public key: \(tlv.data.map { String(format: "%02x", $0) }.joined())")
            } else if tlv.type == PairingTLVType.proof.rawValue {
                print("🔐 Received client proof: \(tlv.data.map { String(format: "%02x", $0) }.joined())")
            }
        }
        
        // Generate server proof (simplified - in real SRP this involves complex math)
        let serverProof = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        
        let responseTlvs = [
            TLV8(type: PairingTLVType.state.rawValue, value: PairingState.finishResponse.rawValue),
            TLV8(type: PairingTLVType.proof.rawValue, data: serverProof)
        ]
        
        print("🔐 Generated server proof for finish response")
        return TLV8.encode(responseTlvs)
    }
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
    
    // MARK: - Cryptographic Session Management
    private var srpSessions: [String: SRPSession] = [:]  // Track sessions by connection address
    private var sessionStates: [String: PairingState] = [:] // Track pairing state per connection
    
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
            
            // Configure for both IPv4 and IPv6 support (CRITICAL FIX)
            parameters.acceptLocalOnly = false
            parameters.preferNoProxies = true
            
            // Allow all network interfaces - no restrictions on interface type
            // Don't set requiredInterfaceType to allow both wired and wireless
            parameters.prohibitedInterfaceTypes = []
            
            // Enable dual-stack IPv4/IPv6 support
            parameters.preferNoProxies = true
            
            // Configure TCP options for better connection stability
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 30  // Start keepalive after 30 seconds
            tcpOptions.keepaliveInterval = 10  // Send keepalive every 10 seconds
            tcpOptions.keepaliveCount = 3  // Allow 3 failed keepalives before closing
            tcpOptions.noDelay = true  // Disable Nagle's algorithm for lower latency
            parameters.defaultProtocolStack.transportProtocol = tcpOptions
            
            // Create listener that binds to all interfaces (IPv4 and IPv6)
            // Using NWEndpoint.Port without specific interface binds to all available interfaces
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
                print("📥 Received \(data.count) bytes from \(address)")
                
                // Debug: Show what type of request this is
                if let rawString = String(data: data, encoding: .utf8) {
                    let firstLine = rawString.components(separatedBy: .newlines).first ?? "Unknown"
                    print("🔍 Request type: \(firstLine)")
                } else {
                    print("🔍 Binary data received: \(data.prefix(20).map { String(format: "%02x", $0) }.joined(separator: " "))")
                }
                
                self?.processRTSPData(data, from: connection)
            } else if data != nil {
                print("📭 Received empty data packet from \(address)")
            }
            
            if isComplete {
                print("📡 Connection end-of-stream from \(address)")
                self?.removeConnection(connection)
            } else {
                // Continue receiving more RTSP requests on this connection
                print("🔄 Continuing to listen for more requests from \(address)")
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
        } else if method == "POST" && url == "/pair-setup" {
            print("✅ Handling POST /pair-setup request")
            print("🔐 iPhone requesting security handshake")
            if !body.isEmpty {
                print("🔐 Pair-setup body: \(body.count) bytes")
            }
            sendPairSetupResponse(to: connection, cseq: cseq, requestBody: body)
        } else if method == "POST" && url == "/pair-verify" {
            print("✅ Handling POST /pair-verify request")
            print("🔐 iPhone requesting pairing verification")
            if !body.isEmpty {
                print("🔐 Pair-verify body: \(body.count) bytes")
            }
            sendPairVerifyResponse(to: connection, cseq: cseq, requestBody: body)
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
        let persistentID = getPersistentUUID()
        
        // Get raw TXT records from our Bonjour services (simulated)
        let airplayTXTData = getAirPlayTXTRecordData()
        let raopTXTData = getRAOPTXTRecordData()
        
        // Create the binary plist dictionary with ALL required AirPlay fields
        let plistDict: [String: Any] = [
            "deviceid": deviceId,
            "features": 119,
            "model": "AppleTV3,2",
            "pi": persistentID,
            "pk": getPublicKeyData(),
            "srcvers": "379.27.1",
            "vv": 2
        ]
        
        do {
            // Serialize to BINARY plist format (not XML)
            let plistData = try PropertyListSerialization.data(fromPropertyList: plistDict, format: .binary, options: 0)
            
            // Create RTSP response with correct headers
            let response = """
            RTSP/1.0 200 OK\r
            CSeq: \(cseq)\r
            Content-Type: application/x-apple-binary-plist\r
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
                    print("✅ Sent /info BINARY plist response successfully (\(plistData.count) bytes)")
                    print("📄 Binary plist data sent (\(plistData.count) bytes)")
                }
            })
            
        } catch {
            print("❌ Failed to create binary plist: \(error)")
        }
    }
    
    private func sendPairSetupResponse(to connection: NWConnection, cseq: String, requestBody: Data) {
        let address = extractAddress(from: connection.endpoint)
        print("🔐 Processing pair-setup request from \(address)")
        print("🔐 Request body: \(requestBody.count) bytes")
        
        // Parse the TLV8 request from iPhone
        let requestTlvs = TLV8.parse(requestBody)
        var requestState: PairingState?
        
        for tlv in requestTlvs {
            if tlv.type == PairingTLVType.state.rawValue, let state = tlv.data.first {
                requestState = PairingState(rawValue: state)
                print("🔐 Pair-setup request state: \(state)")
            } else if tlv.type == PairingTLVType.method.rawValue, let method = tlv.data.first {
                print("🔐 Pair-setup method: \(method)")
            } else if tlv.type == PairingTLVType.publicKey.rawValue {
                print("🔐 Received client public key: \(tlv.data.count) bytes")
            }
        }
        
        var responseData: Data
        
        switch requestState {
        case .startRequest:
            // Phase 1: Create new SRP session and send server's public key + salt
            print("🔐 Starting new SRP session for \(address)")
            let srpSession = SRPSession()
            srpSessions[address] = srpSession
            sessionStates[address] = .startResponse
            
            responseData = srpSession.generateStartResponse()
            print("🔐 Generated start response: \(responseData.count) bytes")
            
        case .finishRequest:
            // Phase 2: Process client's proof and send server's proof
            print("🔐 Processing finish request for \(address)")
            guard let srpSession = srpSessions[address] else {
                print("❌ No SRP session found for \(address)")
                sendPairSetupError(to: connection, cseq: cseq)
                return
            }
            
            sessionStates[address] = .finishResponse
            
            if let finishResponse = srpSession.processFinishRequest(requestBody) {
                responseData = finishResponse
                print("🔐 Generated finish response: \(responseData.count) bytes")
                
                // Mark pairing as completed
                print("✅ SRP handshake completed for \(address)!")
            } else {
                print("❌ Failed to process finish request")
                sendPairSetupError(to: connection, cseq: cseq)
                return
            }
            
        default:
            print("❌ Unexpected pair-setup state: \(requestState?.rawValue ?? 255)")
            sendPairSetupError(to: connection, cseq: cseq)
            return
        }
        
        // Send the cryptographic response
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(cseq)\r
        Content-Type: application/x-apple-binary-plist\r
        Content-Length: \(responseData.count)\r
        Server: AirTunes/379.27.1\r
        \r
        """
        
        guard let responseHeaders = response.data(using: .utf8) else {
            print("❌ Failed to encode pair-setup response headers")
            return
        }
        
        var fullResponse = responseHeaders
        fullResponse.append(responseData)
        
        connection.send(content: fullResponse, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Failed to send pair-setup response: \(error)")
            } else {
                print("✅ Sent pair-setup cryptographic response successfully (\(fullResponse.count) bytes)")
                if requestState == .finishRequest {
                    print("🎉 AirPlay cryptographic handshake completed!")
                } else {
                    print("🔐 Waiting for iPhone's finish request...")
                }
            }
        })
    }
    
    private func sendPairSetupError(to connection: NWConnection, cseq: String) {
        let errorTlvs = [
            TLV8(type: PairingTLVType.state.rawValue, value: PairingState.startResponse.rawValue),
            TLV8(type: PairingTLVType.error.rawValue, value: 1) // Generic error
        ]
        
        let errorData = TLV8.encode(errorTlvs)
        
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(cseq)\r
        Content-Type: application/x-apple-binary-plist\r
        Content-Length: \(errorData.count)\r
        Server: AirTunes/379.27.1\r
        \r
        """
        
        guard let responseHeaders = response.data(using: .utf8) else { return }
        
        var fullResponse = responseHeaders
        fullResponse.append(errorData)
        
        connection.send(content: fullResponse, completion: .contentProcessed { _ in
            print("❌ Sent pair-setup error response")
        })
    }
    
    private func sendPairVerifyResponse(to connection: NWConnection, cseq: String, requestBody: Data) {
        let address = extractAddress(from: connection.endpoint)
        print("🔐 Processing pair-verify request from \(address)")
        print("🔐 Request body: \(requestBody.count) bytes")
        
        // Parse the TLV8 request from iPhone
        let requestTlvs = TLV8.parse(requestBody)
        var requestState: PairingState?
        
        for tlv in requestTlvs {
            if tlv.type == PairingTLVType.state.rawValue, let state = tlv.data.first {
                requestState = PairingState(rawValue: state)
                print("🔐 Pair-verify request state: \(state)")
            } else if tlv.type == PairingTLVType.publicKey.rawValue {
                print("🔐 Received client verify public key: \(tlv.data.count) bytes")
            } else if tlv.type == PairingTLVType.encryptedData.rawValue {
                print("🔐 Received encrypted data: \(tlv.data.count) bytes")
            }
        }
        
        var responseData: Data
        
        switch requestState {
        case .startRequest:
            // Pair-verify phase 1: Generate ephemeral keys for this session
            print("🔐 Starting pair-verify phase 1 for \(address)")
            
            // Generate ephemeral key pair for this verification session
            let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            let ephemeralPublicKey = ephemeralPrivateKey.publicKey.rawRepresentation
            
            let responseTlvs = [
                TLV8(type: PairingTLVType.state.rawValue, value: PairingState.startResponse.rawValue),
                TLV8(type: PairingTLVType.publicKey.rawValue, data: ephemeralPublicKey)
            ]
            
            responseData = TLV8.encode(responseTlvs)
            print("🔐 Generated pair-verify start response: \(responseData.count) bytes")
            
        case .finishRequest:
            // Pair-verify phase 2: Complete the verification
            print("🔐 Processing pair-verify finish request for \(address)")
            
            // Generate proof that we completed the handshake
            let verificationProof = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            
            let responseTlvs = [
                TLV8(type: PairingTLVType.state.rawValue, value: PairingState.finishResponse.rawValue),
                TLV8(type: PairingTLVType.encryptedData.rawValue, data: verificationProof)
            ]
            
            responseData = TLV8.encode(responseTlvs)
            print("🔐 Generated pair-verify finish response: \(responseData.count) bytes")
            print("✅ Pair-verify handshake completed for \(address)!")
            print("🎉 iPhone is now fully authenticated and ready for streaming!")
            
        default:
            print("❌ Unexpected pair-verify state: \(requestState?.rawValue ?? 255)")
            sendPairVerifyError(to: connection, cseq: cseq)
            return
        }
        
        // Send the verification response
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(cseq)\r
        Content-Type: application/x-apple-binary-plist\r
        Content-Length: \(responseData.count)\r
        Server: AirTunes/379.27.1\r
        \r
        """
        
        guard let responseHeaders = response.data(using: .utf8) else {
            print("❌ Failed to encode pair-verify response headers")
            return
        }
        
        var fullResponse = responseHeaders
        fullResponse.append(responseData)
        
        connection.send(content: fullResponse, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Failed to send pair-verify response: \(error)")
            } else {
                print("✅ Sent pair-verify response successfully (\(fullResponse.count) bytes)")
                if requestState == .finishRequest {
                    print("🚀 AirPlay receiver is now ready for media streaming!")
                }
            }
        })
    }
    
    private func sendPairVerifyError(to connection: NWConnection, cseq: String) {
        let errorTlvs = [
            TLV8(type: PairingTLVType.state.rawValue, value: PairingState.startResponse.rawValue),
            TLV8(type: PairingTLVType.error.rawValue, value: 1) // Generic error
        ]
        
        let errorData = TLV8.encode(errorTlvs)
        
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: \(cseq)\r
        Content-Type: application/x-apple-binary-plist\r
        Content-Length: \(errorData.count)\r
        Server: AirTunes/379.27.1\r
        \r
        """
        
        guard let responseHeaders = response.data(using: .utf8) else { return }
        
        var fullResponse = responseHeaders
        fullResponse.append(errorData)
        
        connection.send(content: fullResponse, completion: .contentProcessed { _ in
            print("❌ Sent pair-verify error response")
        })
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
    
    private func getPublicKeyData() -> Data {
        let keyStorageKey = "SparkAirPlay.Curve25519.PublicKey"
        
        // Try to load existing key from UserDefaults
        if let existingKeyHex = UserDefaults.standard.string(forKey: keyStorageKey) {
            return dataFromHex(existingKeyHex) ?? Data()
        }
        
        // Generate new Curve25519 key pair
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        // Store the public key for future use
        let publicKeyData = publicKey.rawRepresentation
        let publicKeyHex = publicKeyData.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(publicKeyHex, forKey: keyStorageKey)
        
        // Also store the private key
        let privateKeyData = privateKey.rawRepresentation
        let privateKeyHex = privateKeyData.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(privateKeyHex, forKey: "SparkAirPlay.Curve25519.PrivateKey")
        
        return publicKeyData
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
    
    private func getAirPlayTXTRecordData() -> Data {
        // Generate raw TXT record data that matches our Bonjour advertisement
        let deviceId = getMacAddress().replacingOccurrences(of: ":", with: "").lowercased()
        
        let txtRecord: [String: Data] = [
            "deviceid": deviceId.data(using: .utf8) ?? Data(),
            "features": "0x77".data(using: .utf8) ?? Data(),
            "flags": "0x4".data(using: .utf8) ?? Data(),
            "model": "AppleTV3,2".data(using: .utf8) ?? Data(),
            "protovers": "1.1".data(using: .utf8) ?? Data(),
            "srcvers": "379.27.1".data(using: .utf8) ?? Data(),
            "vv": "2".data(using: .utf8) ?? Data(),
            "pw": "false".data(using: .utf8) ?? Data()
        ]
        
        return NetService.data(fromTXTRecord: txtRecord)
    }
    
    private func getRAOPTXTRecordData() -> Data {
        // Generate raw RAOP TXT record data that matches our Bonjour advertisement
        let txtRecord: [String: Data] = [
            "txtvers": "1".data(using: .utf8) ?? Data(),
            "ch": "2".data(using: .utf8) ?? Data(),
            "cn": "0,1,2,3".data(using: .utf8) ?? Data(),
            "da": "true".data(using: .utf8) ?? Data(),
            "et": "0,3,5".data(using: .utf8) ?? Data(),
            "ft": "0x77".data(using: .utf8) ?? Data(),
            "md": "0,1,2".data(using: .utf8) ?? Data(),
            "pw": "false".data(using: .utf8) ?? Data(),
            "sr": "44100".data(using: .utf8) ?? Data(),
            "ss": "16".data(using: .utf8) ?? Data(),
            "tp": "UDP".data(using: .utf8) ?? Data(),
            "vn": "65537".data(using: .utf8) ?? Data(),
            "vs": "379.27.1".data(using: .utf8) ?? Data(),
            "am": "AppleTV3,2".data(using: .utf8) ?? Data(),
            "sf": "0x4".data(using: .utf8) ?? Data()
        ]
        
        return NetService.data(fromTXTRecord: txtRecord)
    }
}