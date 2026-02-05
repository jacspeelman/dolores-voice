// WebSocketManager.swift
// Dolores Voice - iOS Voice Assistant
//
// Manages WebSocket connection for real-time communication
// with the voice assistant backend.

import Foundation
import Combine

/// Messages that can be sent to the server
enum ClientMessage: Codable {
    case audio(Data)
    case text(String)
    case ping
    
    private enum CodingKeys: String, CodingKey {
        case type, data, text
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .audio(let data):
            try container.encode("audio", forKey: .type)
            try container.encode(data.base64EncodedString(), forKey: .data)
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .ping:
            try container.encode("ping", forKey: .type)
        }
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "audio":
            let base64 = try container.decode(String.self, forKey: .data)
            guard let data = Data(base64Encoded: base64) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.data], debugDescription: "Invalid base64"))
            }
            self = .audio(data)
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "ping":
            self = .ping
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown type"))
        }
    }
}

/// Messages received from the server
enum ServerMessage: Codable {
    case transcript(String)
    case response(String)
    case audio(Data)
    case error(String)
    case pong
    
    private enum CodingKeys: String, CodingKey {
        case type, text, data, error
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "transcript":
            let text = try container.decode(String.self, forKey: .text)
            self = .transcript(text)
        case "response":
            let text = try container.decode(String.self, forKey: .text)
            self = .response(text)
        case "audio":
            let base64 = try container.decode(String.self, forKey: .data)
            guard let data = Data(base64Encoded: base64) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.data], debugDescription: "Invalid base64"))
            }
            self = .audio(data)
        case "error":
            let error = try container.decode(String.self, forKey: .error)
            self = .error(error)
        case "pong":
            self = .pong
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown type"))
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .transcript(let text):
            try container.encode("transcript", forKey: .type)
            try container.encode(text, forKey: .text)
        case .response(let text):
            try container.encode("response", forKey: .type)
            try container.encode(text, forKey: .text)
        case .audio(let data):
            try container.encode("audio", forKey: .type)
            try container.encode(data.base64EncodedString(), forKey: .data)
        case .error(let error):
            try container.encode("error", forKey: .type)
            try container.encode(error, forKey: .error)
        case .pong:
            try container.encode("pong", forKey: .type)
        }
    }
}

/// Manages WebSocket connection to the voice assistant backend
@MainActor
class WebSocketManager: ObservableObject {
    // MARK: - Configuration
    
    /// WebSocket server URL - TODO: Configure with actual server
    private let serverURL: URL = URL(string: "wss://your-server.example.com/voice")!
    
    // MARK: - Published Properties
    
    /// Connection state
    @Published var isConnected = false
    
    /// Last received transcript
    @Published var lastTranscript: String?
    
    /// Last received response
    @Published var lastResponse: String?
    
    /// Last error message
    @Published var lastError: String?
    
    // MARK: - Private Properties
    
    /// WebSocket task
    private var webSocketTask: URLSessionWebSocketTask?
    
    /// URL session for WebSocket
    private let session: URLSession
    
    /// Ping timer
    private var pingTimer: Timer?
    
    /// Reconnection attempts
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    
    /// Handlers for received messages
    var onTranscript: ((String) -> Void)?
    var onResponse: ((String) -> Void)?
    var onAudioResponse: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    
    // MARK: - Initialization
    
    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - Public Methods
    
    /// Connect to the WebSocket server
    func connect() {
        guard !isConnected else { return }
        
        print("🔌 Connecting to WebSocket: \(serverURL)")
        
        webSocketTask = session.webSocketTask(with: serverURL)
        webSocketTask?.resume()
        
        isConnected = true
        reconnectAttempts = 0
        
        // Start receiving messages
        receiveMessage()
        
        // Start ping timer
        startPingTimer()
    }
    
    /// Disconnect from the server
    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        
        isConnected = false
        
        print("🔌 Disconnected from WebSocket")
    }
    
    /// Send audio data to the server
    func sendAudio(_ data: Data) async throws {
        let message = ClientMessage.audio(data)
        try await send(message)
    }
    
    /// Send text message to the server
    func sendText(_ text: String) async throws {
        let message = ClientMessage.text(text)
        try await send(message)
    }
    
    // MARK: - Private Methods
    
    /// Send a message to the server
    private func send(_ message: ClientMessage) async throws {
        guard let webSocketTask = webSocketTask else {
            throw WebSocketError.notConnected
        }
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let string = String(data: data, encoding: .utf8)!
        
        try await webSocketTask.send(.string(string))
        print("📤 Sent message: \(message)")
    }
    
    /// Receive messages from the server
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let message):
                    self?.handleMessage(message)
                    // Continue receiving
                    self?.receiveMessage()
                    
                case .failure(let error):
                    print("❌ WebSocket receive error: \(error)")
                    self?.handleDisconnection()
                }
            }
        }
    }
    
    /// Handle received WebSocket message
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseMessage(text)
            }
        @unknown default:
            print("⚠️ Unknown message type received")
        }
    }
    
    /// Parse JSON message from server
    private func parseMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        
        do {
            let decoder = JSONDecoder()
            let message = try decoder.decode(ServerMessage.self, from: data)
            
            switch message {
            case .transcript(let text):
                print("📝 Transcript: \(text)")
                lastTranscript = text
                onTranscript?(text)
                
            case .response(let text):
                print("💬 Response: \(text)")
                lastResponse = text
                onResponse?(text)
                
            case .audio(let audioData):
                print("🔊 Received audio: \(audioData.count) bytes")
                onAudioResponse?(audioData)
                
            case .error(let error):
                print("❌ Server error: \(error)")
                lastError = error
                onError?(error)
                
            case .pong:
                print("🏓 Pong received")
            }
        } catch {
            print("⚠️ Failed to parse message: \(error)")
        }
    }
    
    /// Handle disconnection
    private func handleDisconnection() {
        isConnected = false
        pingTimer?.invalidate()
        
        // Attempt reconnection
        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delay = Double(reconnectAttempts) * 2.0
            
            print("🔄 Reconnecting in \(delay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")
            
            Task {
                try? await Task.sleep(for: .seconds(delay))
                connect()
            }
        } else {
            print("❌ Max reconnection attempts reached")
            lastError = "Connection lost. Please check your network."
        }
    }
    
    /// Start ping timer to keep connection alive
    private func startPingTimer() {
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                try? await self?.send(.ping)
            }
        }
    }
}

/// WebSocket-specific errors
enum WebSocketError: LocalizedError {
    case notConnected
    case encodingFailed
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to server"
        case .encodingFailed:
            return "Failed to encode message"
        }
    }
}
