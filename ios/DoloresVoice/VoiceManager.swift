//
//  VoiceManager.swift
//  DoloresVoice
//
//  Voice assistant with Whisper transcription
//

import SwiftUI
import AVFoundation

/// Chat message for history
struct ChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
    let timestamp = Date()
}

/// Voice interaction state
enum VoiceState: String {
    case disconnected = "Niet verbonden"
    case connecting = "Verbinden..."
    case idle = "Start gesprek"
    case listening = "Luisteren..."
    case transcribing = "Transcriberen..."
    case processing = "Denken..."
    case speaking = "Spreken..."
    case error = "Fout"
    
    var color: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .idle: return .blue
        case .listening: return .green
        case .transcribing: return .cyan
        case .processing: return .orange
        case .speaking: return .purple
        case .error: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .disconnected: return "wifi.slash"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .idle: return "mic.circle.fill"
        case .listening: return "waveform.circle.fill"
        case .transcribing: return "text.bubble"
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
    private let silenceThreshold: Float = 0.015  // Audio level below this = silence
    private let silenceTimeout: TimeInterval = 1.5  // Seconds of silence before sending
    private let minRecordingDuration: TimeInterval = 0.5  // Minimum recording length
    
    // MARK: - Published State
    
    @Published var state: VoiceState = .disconnected
    @Published var lastTranscript: String = ""
    @Published var lastResponse: String = ""
    @Published var errorMessage: String?
    @Published var isConnected: Bool = false
    @Published var isConversationActive: Bool = false
    @Published var audioLevel: Float = 0.0
    @Published var ttsProvider: String = ""
    @Published var ttsVoice: String = ""
    @Published var ttsFlag: String = ""
    @Published var sttProvider: String = ""
    @Published var sttFlag: String = ""
    @Published var canUseSpeech: Bool = false
    @Published var messages: [ChatMessage] = []
    
    // MARK: - Private Properties
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var audioPlayerDelegate: AudioPlayerDelegate?
    private let synthesizer = AVSpeechSynthesizer()
    
    // Audio Recording
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var levelTimer: Timer?
    private var silenceTimer: Timer?
    private var recordingStartTime: Date?
    private var lastSpeechTime: Date = Date()
    private var hasDetectedSpeech: Bool = false
    
    // MARK: - Initialization
    
    init() {
        setupRecordingURL()
    }
    
    private func setupRecordingURL() {
        let tempDir = FileManager.default.temporaryDirectory
        recordingURL = tempDir.appendingPathComponent("voice_recording.m4a")
    }
    
    // MARK: - Permissions
    
    func checkPermissions() {
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            // No speech recognition permission needed - using Whisper server-side
            canUseSpeech = granted
            if !granted {
                errorMessage = "Microfoon toegang vereist"
            }
        }
    }
    
    // MARK: - Connection
    
    func connect() {
        guard webSocketTask == nil else { return }
        
        state = .connecting
        errorMessage = nil
        
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
            }
        }
    }
    
    func disconnect() {
        stopConversation()
        reconnectTask?.cancel()
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
        stopConversation()
        scheduleReconnect()
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        switch type {
        case "transcript":
            // Whisper transcript received
            if let transcript = json["text"] as? String {
                if transcript.isEmpty {
                    // Empty transcript - continue listening
                    lastTranscript = ""
                    if isConversationActive {
                        startRecording()
                    } else {
                        state = isConnected ? .idle : .disconnected
                    }
                } else {
                    messages.append(ChatMessage(isUser: true, text: transcript))
                    lastTranscript = ""  // Clear after adding to messages
                    state = .processing
                }
            }
            
        case "response":
            if let responseText = json["text"] as? String {
                lastResponse = responseText
                messages.append(ChatMessage(isUser: false, text: responseText))
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
                    try? await Task.sleep(for: .seconds(2))
                    if isConversationActive {
                        startRecording()
                    } else {
                        state = isConnected ? .idle : .disconnected
                    }
                    errorMessage = nil
                }
            }
            
        case "pong":
            break
            
        case "config":
            if let tts = json["tts"] as? [String: Any] {
                ttsProvider = tts["provider"] as? String ?? ""
                ttsVoice = tts["voice"] as? String ?? ""
                ttsFlag = tts["flag"] as? String ?? ""
            }
            if let stt = json["stt"] as? [String: Any] {
                sttProvider = stt["provider"] as? String ?? ""
                sttFlag = stt["flag"] as? String ?? ""
            }
            
        default:
            break
        }
    }
    
    // MARK: - Conversation Mode
    
    /// Start continuous conversation
    func startConversation() {
        guard isConnected else { return }
        isConversationActive = true
        startRecording()
    }
    
    /// Stop conversation
    func stopConversation() {
        isConversationActive = false
        stopRecording(send: false)
        state = isConnected ? .idle : .disconnected
    }
    
    /// Toggle conversation on/off
    func toggleConversation() {
        if isConversationActive {
            stopConversation()
        } else {
            startConversation()
        }
    }
    
    // MARK: - Audio Recording
    
    private func startRecording() {
        guard isConnected else { return }
        guard let recordingURL = recordingURL else { return }
        
        // Clean up any existing recording
        stopRecording(send: false)
        
        state = .listening
        hasDetectedSpeech = false
        lastSpeechTime = Date()
        recordingStartTime = Date()
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Recording settings for M4A (AAC) - good quality, small size
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            // Delete old recording if exists
            try? FileManager.default.removeItem(at: recordingURL)
            
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            
            // Start level monitoring
            startLevelMonitoring()
            
        } catch {
            errorMessage = "Opname mislukt: \(error.localizedDescription)"
            state = isConversationActive ? .listening : .idle
        }
    }
    
    private func stopRecording(send: Bool) {
        levelTimer?.invalidate()
        levelTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        audioRecorder?.stop()
        audioRecorder = nil
        
        try? AVAudioSession.sharedInstance().setActive(false)
        
        if send {
            sendRecording()
        }
    }
    
    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateAudioLevel()
            }
        }
    }
    
    private func updateAudioLevel() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        
        recorder.updateMeters()
        let level = recorder.averagePower(forChannel: 0)
        
        // Convert dB to linear (0-1 range)
        let linearLevel = pow(10, level / 20)
        audioLevel = min(linearLevel * 3, 1.0)  // Amplify for visibility
        
        // Detect speech
        if linearLevel > silenceThreshold {
            hasDetectedSpeech = true
            lastSpeechTime = Date()
        }
        
        // Check for silence after speech
        if hasDetectedSpeech {
            let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
            let recordingDuration = Date().timeIntervalSince(recordingStartTime ?? Date())
            
            if silenceDuration >= silenceTimeout && recordingDuration >= minRecordingDuration {
                // Enough silence after speech - send the recording
                stopRecording(send: true)
            }
        }
    }
    
    private func sendRecording() {
        guard let recordingURL = recordingURL else { return }
        
        state = .transcribing
        
        do {
            let audioData = try Data(contentsOf: recordingURL)
            let base64 = audioData.base64EncodedString()
            
            print("📤 Sending audio: \(audioData.count / 1024)KB")
            sendJSON(["type": "audio", "data": base64])
            
        } catch {
            errorMessage = "Kon opname niet lezen"
            if isConversationActive {
                startRecording()
            } else {
                state = isConnected ? .idle : .disconnected
            }
        }
    }
    
    // MARK: - Send Text (manual input)
    
    func sendText(_ text: String) {
        guard !text.isEmpty, isConnected else { return }
        
        state = .processing
        messages.append(ChatMessage(isUser: true, text: text))
        sendJSON(["type": "text", "text": text])
    }
    
    // MARK: - Audio Playback
    
    private func playAudio(_ data: Data) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback)
            try session.setActive(true)
            
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayerDelegate = AudioPlayerDelegate { [weak self] in
                Task { @MainActor in
                    self?.onAudioFinished()
                }
            }
            audioPlayer?.delegate = audioPlayerDelegate
            audioPlayer?.play()
            
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
            onAudioFinished()
        }
    }
    
    private func onAudioFinished() {
        if isConversationActive {
            // Continue listening after I finish speaking
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                startRecording()
            }
        } else {
            state = isConnected ? .idle : .disconnected
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
