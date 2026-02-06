//
//  VoiceManager.swift
//  DoloresVoice
//
//  Manages communication with the Dolores backend
//  Simplified version - text input only, audio output
//

import SwiftUI
import AVFoundation

/// Voice interaction state
enum VoiceState: String {
    case disconnected = "Niet verbonden"
    case connecting = "Verbinden..."
    case idle = "Klaar"
    case processing = "Denken..."
    case speaking = "Spreken..."
    case error = "Fout"
    
    var color: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .idle: return .blue
        case .processing: return .orange
        case .speaking: return .green
        case .error: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .disconnected: return "wifi.slash"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .idle: return "text.bubble.fill"
        case .processing: return "brain"
        case .speaking: return "speaker.wave.3.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
class VoiceManager: ObservableObject {
    // MARK: - Configuration
    
    private let serverURL = URL(string: "ws://192.168.1.214:8765")!
    private let maxReconnectAttempts = 5
    
    // MARK: - Published State
    
    @Published var state: VoiceState = .disconnected
    @Published var lastTranscript: String = ""
    @Published var lastResponse: String = ""
    @Published var errorMessage: String?
    @Published var isConnected: Bool = false
    
    // MARK: - Private Properties
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    
    // MARK: - Connection Management
    
    func connect() {
        guard webSocketTask == nil else { return }
        
        state = .connecting
        errorMessage = nil
        
        print("🔌 Connecting to \(serverURL)...")
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: serverURL)
        webSocketTask?.resume()
        
        receiveMessages()
        
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if webSocketTask != nil {
                sendPing()
                isConnected = true
                state = .idle
                reconnectAttempts = 0
                print("✅ Connected!")
            }
        }
    }
    
    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        state = .disconnected
    }
    
    func reconnect() {
        disconnect()
        reconnectAttempts = 0
        connect()
    }
    
    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            state = .error
            errorMessage = "Kan niet verbinden"
            return
        }
        
        reconnectAttempts += 1
        let delay = Double(min(reconnectAttempts * 2, 10))
        
        state = .connecting
        errorMessage = "Opnieuw verbinden..."
        
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled {
                webSocketTask = nil
                connect()
            }
        }
    }
    
    // MARK: - WebSocket
    
    private func sendPing() {
        sendJSON(["type": "ping"])
    }
    
    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return }
        
        webSocketTask?.send(.string(string)) { [weak self] error in
            if error != nil {
                Task { @MainActor in self?.handleDisconnection() }
            }
        }
    }
    
    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let message):
                    self?.handleMessage(message)
                    self?.receiveMessages()
                case .failure:
                    self?.handleDisconnection()
                }
            }
        }
    }
    
    private func handleDisconnection() {
        isConnected = false
        webSocketTask = nil
        scheduleReconnect()
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        switch type {
        case "response":
            if let responseText = json["text"] as? String {
                lastResponse = responseText
            }
            
        case "audio":
            state = .speaking
            if let base64 = json["data"] as? String,
               let audioData = Data(base64Encoded: base64) {
                playAudio(audioData)
            } else {
                speakWithSystemTTS(lastResponse)
            }
            
        case "error":
            if let error = json["error"] as? String {
                errorMessage = error
                state = .error
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    state = isConnected ? .idle : .disconnected
                    errorMessage = nil
                }
            }
            
        case "pong":
            break
            
        default:
            break
        }
    }
    
    // MARK: - Send Message
    
    func sendText(_ text: String) {
        guard !text.isEmpty, isConnected else { return }
        
        state = .processing
        lastTranscript = text
        sendJSON(["type": "text", "text": text])
    }
    
    // MARK: - Audio Playback
    
    private func playAudio(_ data: Data) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.play()
            
            // Return to idle when done
            let duration = audioPlayer?.duration ?? 2.0
            Task {
                try? await Task.sleep(for: .seconds(duration + 0.3))
                state = isConnected ? .idle : .disconnected
            }
        } catch {
            speakWithSystemTTS(lastResponse)
        }
    }
    
    private func speakWithSystemTTS(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "nl-NL")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
        
        Task {
            try? await Task.sleep(for: .seconds(Double(text.count) / 12.0))
            state = isConnected ? .idle : .disconnected
        }
    }
}
