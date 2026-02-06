//
//  VoiceManager.swift
//  DoloresVoice
//
//  Voice assistant with continuous conversation mode
//

import SwiftUI
import AVFoundation
import Speech

/// Voice interaction state
enum VoiceState: String {
    case disconnected = "Niet verbonden"
    case connecting = "Verbinden..."
    case idle = "Start gesprek"
    case listening = "Luisteren..."
    case processing = "Denken..."
    case speaking = "Spreken..."
    case error = "Fout"
    
    var color: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .idle: return .blue
        case .listening: return .green
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
    private let silenceThreshold: Float = 0.01  // Audio level below this = silence
    private let silenceTimeout: TimeInterval = 1.5  // Seconds of silence before sending
    
    // MARK: - Published State
    
    @Published var state: VoiceState = .disconnected
    @Published var lastTranscript: String = ""
    @Published var lastResponse: String = ""
    @Published var errorMessage: String?
    @Published var isConnected: Bool = false
    @Published var canUseSpeech: Bool = false
    @Published var isConversationActive: Bool = false
    @Published var audioLevel: Float = 0.0
    
    // MARK: - Private Properties
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var audioPlayerDelegate: AudioPlayerDelegate?
    private let synthesizer = AVSpeechSynthesizer()
    
    // Speech Recognition
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // Silence detection
    private var silenceTimer: Timer?
    private var lastSpeechTime: Date = Date()
    private var hasDetectedSpeech: Bool = false
    
    // MARK: - Initialization
    
    init() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "nl-NL"))
    }
    
    // MARK: - Permissions
    
    func checkPermissions() {
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            if granted {
                checkSpeechPermission()
            } else {
                canUseSpeech = false
            }
        }
    }
    
    private func checkSpeechPermission() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            canUseSpeech = true
        case .denied, .restricted:
            canUseSpeech = false
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    self?.canUseSpeech = (status == .authorized)
                }
            }
        @unknown default:
            canUseSpeech = false
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
                    try? await Task.sleep(for: .seconds(2))
                    if isConversationActive {
                        startListening()
                    } else {
                        state = isConnected ? .idle : .disconnected
                    }
                    errorMessage = nil
                }
            }
            
        case "pong":
            break
            
        default:
            break
        }
    }
    
    // MARK: - Conversation Mode
    
    /// Start continuous conversation
    func startConversation() {
        guard isConnected, canUseSpeech else { return }
        isConversationActive = true
        startListening()
    }
    
    /// Stop conversation
    func stopConversation() {
        isConversationActive = false
        stopListening()
        silenceTimer?.invalidate()
        silenceTimer = nil
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
    
    // MARK: - Speech Recognition
    
    private func startListening() {
        guard canUseSpeech, isConnected else { return }
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "Spraakherkenning niet beschikbaar"
            return
        }
        
        // Clean up any existing session
        stopListeningQuietly()
        
        lastTranscript = ""
        hasDetectedSpeech = false
        state = .listening
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
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
                self?.processAudioLevel(buffer: buffer)
            }
            
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                Task { @MainActor in
                    if let result = result {
                        let transcript = result.bestTranscription.formattedString
                        if !transcript.isEmpty {
                            self?.lastTranscript = transcript
                            self?.hasDetectedSpeech = true
                            self?.lastSpeechTime = Date()
                        }
                    }
                }
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            
            // Start silence detection timer
            startSilenceDetection()
            
        } catch {
            errorMessage = "Kon niet starten"
            state = isConversationActive ? .listening : .idle
        }
    }
    
    private func stopListeningQuietly() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
    
    private func stopListening() {
        stopListeningQuietly()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
    
    private func processAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = buffer.frameLength
        
        var sum: Float = 0
        for i in 0..<Int(frames) {
            sum += abs(channelData[i])
        }
        
        let level = sum / Float(frames)
        
        Task { @MainActor in
            audioLevel = min(level * 5, 1.0)
        }
    }
    
    private func startSilenceDetection() {
        lastSpeechTime = Date()
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSilence()
            }
        }
    }
    
    private func checkSilence() {
        guard state == .listening, hasDetectedSpeech else { return }
        
        let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
        
        // If we have speech and enough silence, send the message
        if silenceDuration >= silenceTimeout && !lastTranscript.isEmpty {
            sendCurrentTranscript()
        }
    }
    
    private func sendCurrentTranscript() {
        let transcript = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            if isConversationActive {
                startListening()
            }
            return
        }
        
        stopListeningQuietly()
        sendText(transcript)
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
                startListening()
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
