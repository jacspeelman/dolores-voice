//
//  VoiceManager.swift
//  DoloresVoice
//
//  Manages voice communication with the Dolores backend
//

import SwiftUI
import AVFoundation
import Speech

/// Voice interaction state
enum VoiceState: String {
    case disconnected = "Niet verbonden"
    case connecting = "Verbinden..."
    case idle = "Klaar"
    case listening = "Luisteren..."
    case processing = "Denken..."
    case speaking = "Spreken..."
    case error = "Fout"
    
    var color: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .idle: return .blue
        case .listening: return .red
        case .processing: return .orange
        case .speaking: return .green
        case .error: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .disconnected: return "wifi.slash"
        case .connecting: return "arrow.triangle.2.circlepath"
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
    
    /// Max reconnect attempts
    private let maxReconnectAttempts = 5
    
    // MARK: - Published State
    
    @Published var state: VoiceState = .disconnected
    @Published var lastTranscript: String = ""
    @Published var lastResponse: String = ""
    @Published var errorMessage: String?
    @Published var isConnected: Bool = false
    @Published var hasMicPermission: Bool = false
    @Published var hasSpeechPermission: Bool = false
    
    // MARK: - Private Properties
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    
    // Audio
    private var audioPlayer: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    
    // Speech Recognition
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // MARK: - Initialization
    
    init() {
        // Don't request permissions in init - wait for explicit call
    }
    
    // MARK: - Permissions
    
    func requestPermissions() {
        // Microphone permission
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                self?.hasMicPermission = granted
                if !granted {
                    self?.errorMessage = "Microfoon toegang nodig voor spraak"
                }
            }
        }
        
        // Speech recognition permission
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.hasSpeechPermission = (status == .authorized)
                if status == .authorized {
                    self?.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))
                }
            }
        }
    }
    
    // MARK: - Connection Management
    
    /// Connect to the voice server
    func connect() {
        guard webSocketTask == nil else { return }
        
        state = .connecting
        errorMessage = nil
        
        print("🔌 Connecting to \(serverURL)...")
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: serverURL)
        webSocketTask?.resume()
        
        // Start receiving messages
        receiveMessages()
        
        // Send initial ping to verify connection
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
    
    /// Disconnect from the server
    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        state = .disconnected
        print("🔌 Disconnected")
    }
    
    /// Manually trigger reconnect
    func reconnect() {
        disconnect()
        reconnectAttempts = 0
        connect()
    }
    
    /// Auto-reconnect with exponential backoff
    private func scheduleReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            state = .error
            errorMessage = "Kan niet verbinden na \(maxReconnectAttempts) pogingen"
            return
        }
        
        reconnectAttempts += 1
        let delay = Double(min(reconnectAttempts * 2, 10))
        
        print("🔄 Reconnecting in \(delay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")
        state = .connecting
        errorMessage = "Opnieuw verbinden... (\(reconnectAttempts)/\(maxReconnectAttempts))"
        
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled {
                webSocketTask = nil
                connect()
            }
        }
    }
    
    // MARK: - WebSocket Communication
    
    private func sendPing() {
        let message = ["type": "ping"]
        sendJSON(message)
    }
    
    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return }
        
        webSocketTask?.send(.string(string)) { [weak self] error in
            if let error = error {
                print("❌ Send error: \(error)")
                Task { @MainActor in
                    self?.handleDisconnection()
                }
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
                case .failure(let error):
                    print("❌ Receive error: \(error)")
                    self?.handleDisconnection()
                }
            }
        }
    }
    
    private func handleDisconnection() {
        isConnected = false
        webSocketTask = nil
        stopRecording()
        scheduleReconnect()
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
                speakWithSystemTTS(lastResponse)
            }
            
        case "error":
            if let error = json["error"] as? String {
                errorMessage = error
                state = .error
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    if self.state == .error {
                        self.state = self.isConnected ? .idle : .disconnected
                        self.errorMessage = nil
                    }
                }
            }
            
        case "pong":
            break
            
        default:
            print("⚠️ Unknown message type: \(type)")
        }
    }
    
    // MARK: - Voice Recording (Simplified - Text-based for now)
    
    /// Start listening - simplified version
    func startRecording() {
        guard state == .idle, isConnected else { return }
        
        // For now, just show we're ready - actual speech recognition
        // will be enabled after basic flow works
        state = .listening
        lastTranscript = ""
        
        // If we have speech permission, try to use it
        if hasSpeechPermission && hasMicPermission {
            startSpeechRecognition()
        }
    }
    
    private func startSpeechRecognition() {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            print("⚠️ Speech recognizer not available")
            return
        }
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else { return }
            
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else { return }
            
            recognitionRequest.shouldReportPartialResults = true
            
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }
            
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                Task { @MainActor in
                    if let result = result {
                        self?.lastTranscript = result.bestTranscription.formattedString
                    }
                }
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            print("🎤 Speech recognition started")
            
        } catch {
            print("❌ Speech recognition setup failed: \(error)")
            // Continue without speech recognition - user can use text input
        }
    }
    
    /// Stop recording and send transcript
    func stopRecording() {
        guard state == .listening else { return }
        
        // Stop audio engine
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        
        print("🎤 Recording stopped")
        
        // Send transcript if we have one
        let transcript = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            sendText(transcript)
        } else {
            state = isConnected ? .idle : .disconnected
        }
    }
    
    // MARK: - Send Message
    
    /// Send a text message to Dolores
    func sendText(_ text: String) {
        guard !text.isEmpty, isConnected else { return }
        
        state = .processing
        lastTranscript = text
        
        let message: [String: Any] = ["type": "text", "text": text]
        sendJSON(message)
        
        print("📤 Sent: \(text)")
    }
    
    // MARK: - Audio Playback
    
    private func playAudio(_ data: Data) {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
            
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = AudioPlayerDelegate { [weak self] in
                Task { @MainActor in
                    self?.state = self?.isConnected == true ? .idle : .disconnected
                }
            }
            audioPlayer?.play()
            print("🔊 Playing audio")
            
        } catch {
            print("❌ Audio playback error: \(error)")
            speakWithSystemTTS(lastResponse)
        }
    }
    
    private func speakWithSystemTTS(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "nl-NL")
        utterance.rate = 0.52
        
        synthesizer.speak(utterance)
        
        Task {
            try? await Task.sleep(for: .seconds(Double(text.count) / 15.0 + 1))
            if state == .speaking {
                state = isConnected ? .idle : .disconnected
            }
        }
    }
}

// MARK: - Audio Player Delegate

class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
