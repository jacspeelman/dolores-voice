//
//  VoiceManager.swift
//  DoloresVoice
//
//  Manages voice communication with the Dolores backend
//

import SwiftUI
import AVFoundation

/// Voice interaction state
enum VoiceState: String {
    case idle = "Tik om te praten"
    case listening = "Luisteren..."
    case processing = "Denken..."
    case speaking = "Spreken..."
    case error = "Fout"
    
    var color: Color {
        switch self {
        case .idle: return .blue
        case .listening: return .red
        case .processing: return .orange
        case .speaking: return .green
        case .error: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .idle: return "mic.circle.fill"
        case .listening: return "waveform.circle.fill"
        case .processing: return "brain"
        case .speaking: return "speaker.wave.3.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
class VoiceManager: ObservableObject {
    // MARK: - Configuration
    
    /// Server URL - wijzig dit naar je Mac Mini IP
    private let serverURL = URL(string: "ws://192.168.1.214:8765")!
    
    // MARK: - Published State
    
    @Published var state: VoiceState = .idle
    @Published var lastTranscript: String = ""
    @Published var lastResponse: String = ""
    @Published var errorMessage: String?
    @Published var isConnected: Bool = false
    
    // MARK: - Private Properties
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    
    // MARK: - Public Methods
    
    /// Connect to the voice server
    func connect() {
        guard webSocketTask == nil else { return }
        
        print("🔌 Connecting to \(serverURL)...")
        webSocketTask = URLSession.shared.webSocketTask(with: serverURL)
        webSocketTask?.resume()
        isConnected = true
        receiveMessages()
    }
    
    /// Disconnect from the server
    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }
    
    /// Start recording voice
    func startRecording() {
        guard state == .idle else { return }
        
        Task {
            do {
                try await setupAudioSession()
                state = .listening
                // For now, we'll use a simple text input
                // Full audio recording comes later
            } catch {
                errorMessage = error.localizedDescription
                state = .error
            }
        }
    }
    
    /// Stop recording and send to server
    func stopRecording() {
        guard state == .listening else { return }
        state = .idle
    }
    
    /// Send a text message to Dolores
    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        
        connect()
        state = .processing
        lastTranscript = text
        
        let message = ["type": "text", "text": text]
        
        if let data = try? JSONSerialization.data(withJSONObject: message),
           let string = String(data: data, encoding: .utf8) {
            webSocketTask?.send(.string(string)) { [weak self] error in
                if let error = error {
                    Task { @MainActor in
                        self?.errorMessage = error.localizedDescription
                        self?.state = .error
                    }
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
    }
    
    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let message):
                    self?.handleMessage(message)
                    self?.receiveMessages() // Continue listening
                case .failure(let error):
                    print("❌ WebSocket error: \(error)")
                    self?.isConnected = false
                    self?.state = .error
                    self?.errorMessage = "Verbinding verloren"
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseServerMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseServerMessage(text)
            }
        @unknown default:
            break
        }
    }
    
    private func parseServerMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        
        switch type {
        case "response":
            if let responseText = json["text"] as? String {
                lastResponse = responseText
                print("💬 Response: \(responseText)")
            }
            
        case "audio":
            state = .speaking
            if let base64 = json["data"] as? String,
               let audioData = Data(base64Encoded: base64) {
                playAudio(audioData)
            } else {
                // No audio, use system TTS as fallback
                speakWithSystemTTS(lastResponse)
            }
            
        case "error":
            if let error = json["error"] as? String {
                errorMessage = error
                state = .error
            }
            
        case "pong":
            break
            
        default:
            print("⚠️ Unknown message type: \(type)")
        }
    }
    
    private func playAudio(_ data: Data) {
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = nil
            audioPlayer?.play()
            
            // Return to idle after audio finishes
            let duration = audioPlayer?.duration ?? 2.0
            Task {
                try? await Task.sleep(for: .seconds(duration + 0.5))
                if state == .speaking {
                    state = .idle
                }
            }
        } catch {
            print("❌ Audio playback error: \(error)")
            speakWithSystemTTS(lastResponse)
        }
    }
    
    private func speakWithSystemTTS(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "nl-NL")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
        
        // Return to idle after speaking
        Task {
            try? await Task.sleep(for: .seconds(2))
            if state == .speaking {
                state = .idle
            }
        }
    }
}
