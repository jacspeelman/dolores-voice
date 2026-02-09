//
//  VoiceManager.swift
//  DoloresVoice
//
//  Voice assistant with real-time transcription
//  v3: Real-time Speech-to-Text streaming with Azure
//

import SwiftUI
import AVFoundation

/// Chat message for history
struct ChatMessage: Identifiable {
    let id = UUID()
    let isUser: Bool
    var text: String
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
    case streaming = "Antwoord..."
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
        case .streaming: return .yellow
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
        case .streaming: return "text.bubble.fill"
        case .speaking: return "speaker.wave.3.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

/// Streaming audio player using AVAudioEngine
class StreamingAudioPlayer {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var audioChunks: [Data] = []
    private var isPlaying = false
    private var currentChunkIndex = 0
    private var onComplete: (() -> Void)?
    
    func prepare() {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        
        guard let engine = audioEngine, let player = playerNode else { return }
        
        engine.attach(player)
        
        // Standard format for MP3 decoded audio
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        
        do {
            try engine.start()
        } catch {
            print("⚠️ AudioEngine start failed: \(error)")
        }
    }
    
    func addChunk(_ data: Data) {
        audioChunks.append(data)
        
        // Start playing if not already
        if !isPlaying {
            playNextChunk()
        }
    }
    
    func finalize(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        
        // If all chunks are already played, complete immediately
        if currentChunkIndex >= audioChunks.count && !isPlaying {
            cleanup()
            onComplete()
        }
    }
    
    private var nextPlayer: AVAudioPlayer?
    
    private func playNextChunk() {
        guard currentChunkIndex < audioChunks.count else {
            isPlaying = false
            if onComplete != nil {
                cleanup()
                onComplete?()
                onComplete = nil
            }
            return
        }
        
        isPlaying = true
        let chunkData = audioChunks[currentChunkIndex]
        currentChunkIndex += 1
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            do {
                // Use pre-buffered player if available, otherwise create new one
                let player: AVAudioPlayer
                if let preBuffered = self?.nextPlayer {
                    player = preBuffered
                    self?.nextPlayer = nil
                } else {
                    player = try AVAudioPlayer(data: chunkData)
                    player.prepareToPlay()
                }
                
                // Pre-buffer the NEXT chunk while current one plays
                if let self = self, self.currentChunkIndex < self.audioChunks.count {
                    let nextData = self.audioChunks[self.currentChunkIndex]
                    self.nextPlayer = try? AVAudioPlayer(data: nextData)
                    self.nextPlayer?.prepareToPlay()
                }
                
                player.play()
                
                // Wait for playback to complete
                while player.isPlaying {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                
                DispatchQueue.main.async {
                    self?.playNextChunk()
                }
            } catch {
                print("⚠️ Chunk playback failed: \(error)")
                DispatchQueue.main.async {
                    self?.playNextChunk()
                }
            }
        }
    }
    
    func stop() {
        cleanup()
    }
    
    private func cleanup() {
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        audioChunks.removeAll()
        currentChunkIndex = 0
        isPlaying = false
    }
}

@MainActor
class VoiceManager: ObservableObject {
    // MARK: - Configuration
    
    private let serverURL = URL(string: "ws://192.168.1.214:8765")!
    private let maxReconnectAttempts = 5
    private let silenceThreshold: Float = 0.015
    private let silenceTimeout: TimeInterval = 0.8  // Faster response after silence
    private let minRecordingDuration: TimeInterval = 0.3
    
    // MARK: - Published State
    
    @Published var state: VoiceState = .disconnected
    @Published var lastTranscript: String = ""
    @Published var interimTranscript: String = ""  // Real-time interim (can change)
    @Published var lastResponse: String = ""
    @Published var streamingResponse: String = ""  // For progressive display
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
    @Published var streamingEnabled: Bool = true
    @Published var sttStreamingEnabled: Bool = false
    @Published var sttStreamingAvailable: Bool = false
    
    // MARK: - Private Properties
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var audioPlayerDelegate: AudioPlayerDelegate?
    private let synthesizer = AVSpeechSynthesizer()
    
    // Streaming audio
    private var streamingAudioPlayer: StreamingAudioPlayer?
    private var expectedAudioChunks = 0
    private var receivedAudioChunks = 0
    private var currentStreamingMessageId: UUID?
    
    // Audio Recording
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var levelTimer: Timer?
    private var silenceTimer: Timer?
    private var recordingStartTime: Date?
    private var lastSpeechTime: Date = Date()
    private var hasDetectedSpeech: Bool = false
    
    // STT Streaming
    private var audioEngine: AVAudioEngine?
    private var isSTTStreamingActive: Bool = false
    private var sttStreamStarted: Bool = false
    private var audioChunkTimer: Timer?
    private var pcmBuffer: Data = Data()
    private let audioChunkIntervalMs: Double = 150  // Send chunks every 150ms
    
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
            if let transcript = json["text"] as? String {
                if transcript.isEmpty {
                    lastTranscript = ""
                    if isConversationActive {
                        startRecording()
                    } else {
                        state = isConnected ? .idle : .disconnected
                    }
                } else {
                    messages.append(ChatMessage(isUser: true, text: transcript))
                    lastTranscript = ""
                    state = .processing
                }
            }
            
        case "text_delta":
            // Streaming text chunk
            if let delta = json["delta"] as? String {
                // Only create new message if we don't have one yet
                if currentStreamingMessageId == nil {
                    state = .streaming
                    streamingResponse = ""
                    // Add placeholder message for streaming response
                    let newMessage = ChatMessage(isUser: false, text: "")
                    currentStreamingMessageId = newMessage.id
                    messages.append(newMessage)
                }
                
                streamingResponse += delta
                
                // Update the last message with streaming content
                if let msgId = currentStreamingMessageId,
                   let index = messages.firstIndex(where: { $0.id == msgId }) {
                    messages[index].text = streamingResponse
                }
            }
            
        case "text_done":
            // Streaming text complete
            lastResponse = streamingResponse
            currentStreamingMessageId = nil
            // State will change when audio starts or if no audio
            
        case "response":
            // Full response (backwards compatibility or fallback)
            if let responseText = json["text"] as? String {
                // Only add if we didn't already stream it
                if streamingResponse.isEmpty {
                    lastResponse = responseText
                    messages.append(ChatMessage(isUser: false, text: responseText))
                }
                streamingResponse = ""
                
                // If not waiting for audio, go back to idle
                if expectedAudioChunks == 0 && !isConversationActive {
                    state = isConnected ? .idle : .disconnected
                }
            }
            
        case "audio_start":
            // Prepare for streaming audio
            state = .speaking
            expectedAudioChunks = json["chunks"] as? Int ?? 1
            receivedAudioChunks = 0
            streamingAudioPlayer = StreamingAudioPlayer()
            streamingAudioPlayer?.prepare()
            
            // Setup audio session for playback
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback)
                try session.setActive(true)
            } catch {
                print("⚠️ Audio session setup failed: \(error)")
            }
            
        case "audio_chunk":
            // Streaming audio chunk
            if let base64 = json["data"] as? String,
               let audioData = Data(base64Encoded: base64) {
                receivedAudioChunks += 1
                streamingAudioPlayer?.addChunk(audioData)
            }
            
        case "audio_done":
            // All audio chunks received
            streamingAudioPlayer?.finalize { [weak self] in
                Task { @MainActor in
                    self?.onAudioFinished()
                }
            }
            expectedAudioChunks = 0
            receivedAudioChunks = 0
            
        case "audio":
            // Non-streaming audio (backwards compatibility)
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
                streamingResponse = ""
                currentStreamingMessageId = nil
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
                sttStreamingAvailable = stt["streaming"] as? Bool ?? false
            }
            if let streaming = json["streaming"] as? Bool {
                streamingEnabled = streaming
            }
            if let sttStreaming = json["sttStreaming"] as? Bool {
                sttStreamingEnabled = sttStreaming
                sttStreamingAvailable = sttStreaming
            }
            
        case "stt_stream_started":
            // Server confirmed STT streaming is active
            sttStreamStarted = true
            print("🎙️ STT streaming confirmed by server")
            
        case "stt_stream_unavailable":
            // Server doesn't support STT streaming, fallback to Whisper
            sttStreamingEnabled = false
            sttStreamingAvailable = false
            print("⚠️ STT streaming unavailable, using Whisper fallback")
            stopSTTStreaming()
            // Fall back to regular recording
            startRecordingForWhisper()
            
        case "stt_stream_error":
            // Error during STT streaming, fallback to Whisper
            if let error = json["error"] as? String {
                print("⚠️ STT stream error: \(error)")
            }
            stopSTTStreaming()
            startRecordingForWhisper()
            
        case "transcript_interim":
            // Real-time interim transcript (can change)
            if let interim = json["text"] as? String {
                interimTranscript = interim
            }
            
        case "transcript_final":
            // Final segment of transcript (won't change)
            if let final = json["text"] as? String {
                // Append to lastTranscript for display
                if lastTranscript.isEmpty {
                    lastTranscript = final
                } else {
                    lastTranscript += " " + final
                }
                // Clear interim since we have final
                interimTranscript = ""
            }
            
        case "transcript_complete":
            // Complete transcript from streaming session
            if let complete = json["text"] as? String {
                lastTranscript = complete
                interimTranscript = ""
            }
            
        default:
            break
        }
    }
    
    // MARK: - Conversation Mode
    
    func startConversation() {
        guard isConnected else { return }
        isConversationActive = true
        startRecording()
    }
    
    func stopConversation() {
        isConversationActive = false
        stopRecording(send: false)
        stopSTTStreaming()
        streamingAudioPlayer?.stop()
        streamingAudioPlayer = nil
        interimTranscript = ""
        state = isConnected ? .idle : .disconnected
    }
    
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
        
        // Reset state
        lastTranscript = ""
        interimTranscript = ""
        hasDetectedSpeech = false
        lastSpeechTime = Date()
        recordingStartTime = Date()
        state = .listening
        
        // Use STT streaming if available, otherwise fall back to Whisper
        if sttStreamingEnabled && sttStreamingAvailable {
            startSTTStreaming()
        } else {
            startRecordingForWhisper()
        }
    }
    
    /// Start recording for Whisper (traditional approach)
    private func startRecordingForWhisper() {
        guard let recordingURL = recordingURL else { return }
        
        stopRecording(send: false)
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            try? FileManager.default.removeItem(at: recordingURL)
            
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            
            startLevelMonitoring()
            
        } catch {
            errorMessage = "Opname mislukt: \(error.localizedDescription)"
            state = isConversationActive ? .listening : .idle
        }
    }
    
    /// Start real-time STT streaming with AVAudioEngine
    private func startSTTStreaming() {
        stopSTTStreaming()
        
        isSTTStreamingActive = true
        sttStreamStarted = false
        pcmBuffer = Data()
        
        // Tell server to start STT streaming session
        sendJSON(["type": "audio_stream_start"])
        
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            audioEngine = AVAudioEngine()
            guard let engine = audioEngine else { return }
            
            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            // Target format: 16kHz, 16-bit mono PCM (Azure requirement)
            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                   sampleRate: 16000,
                                                   channels: 1,
                                                   interleaved: true) else {
                print("⚠️ Failed to create target audio format")
                startRecordingForWhisper()
                return
            }
            
            // Audio converter for format conversion
            guard let converter = AVAudioConverter(from: recordingFormat, to: targetFormat) else {
                print("⚠️ Failed to create audio converter")
                startRecordingForWhisper()
                return
            }
            
            // Install tap to capture audio
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, time in
                guard let self = self, self.isSTTStreamingActive else { return }
                
                // Convert to 16kHz 16-bit PCM
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / recordingFormat.sampleRate)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }
                
                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                
                converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
                
                if error == nil, let channelData = convertedBuffer.int16ChannelData {
                    let byteCount = Int(convertedBuffer.frameLength) * 2  // 16-bit = 2 bytes
                    let data = Data(bytes: channelData[0], count: byteCount)
                    
                    DispatchQueue.main.async {
                        self.pcmBuffer.append(data)
                        
                        // Calculate audio level for UI
                        var sum: Float = 0
                        for i in 0..<Int(convertedBuffer.frameLength) {
                            let sample = Float(channelData[0][i]) / Float(Int16.max)
                            sum += sample * sample
                        }
                        let rms = sqrt(sum / Float(convertedBuffer.frameLength))
                        self.audioLevel = min(rms * 5, 1.0)
                        
                        // Update silence detection
                        if rms > self.silenceThreshold {
                            self.hasDetectedSpeech = true
                            self.lastSpeechTime = Date()
                        }
                    }
                }
            }
            
            engine.prepare()
            try engine.start()
            
            // Start timer to send audio chunks periodically
            audioChunkTimer = Timer.scheduledTimer(withTimeInterval: audioChunkIntervalMs / 1000.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.sendAudioChunk()
                }
            }
            
            // Start silence monitoring
            startSilenceMonitoring()
            
            print("🎙️ STT streaming started with AVAudioEngine")
            
        } catch {
            print("⚠️ AVAudioEngine setup failed: \(error)")
            isSTTStreamingActive = false
            startRecordingForWhisper()
        }
    }
    
    /// Send accumulated PCM audio chunk to server
    private func sendAudioChunk() {
        guard isSTTStreamingActive, !pcmBuffer.isEmpty else { return }
        
        let chunk = pcmBuffer
        pcmBuffer = Data()
        
        let base64 = chunk.base64EncodedString()
        sendJSON(["type": "audio_stream_chunk", "data": base64])
    }
    
    /// Stop STT streaming
    private func stopSTTStreaming() {
        isSTTStreamingActive = false
        sttStreamStarted = false
        
        audioChunkTimer?.invalidate()
        audioChunkTimer = nil
        
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        
        pcmBuffer = Data()
    }
    
    /// Monitor silence during STT streaming
    private func startSilenceMonitoring() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSilenceForSTTStreaming()
            }
        }
    }
    
    /// Check for silence to end STT streaming
    private func checkSilenceForSTTStreaming() {
        guard isSTTStreamingActive else { return }
        
        let recordingDuration = Date().timeIntervalSince(recordingStartTime ?? Date())
        
        if hasDetectedSpeech {
            let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
            
            if silenceDuration >= silenceTimeout && recordingDuration >= minRecordingDuration {
                // End STT streaming
                endSTTStreaming()
            }
        }
    }
    
    /// End STT streaming and request final transcript
    private func endSTTStreaming() {
        guard isSTTStreamingActive else { return }
        
        state = .transcribing
        
        // Send any remaining audio
        sendAudioChunk()
        
        // Tell server to end the session
        sendJSON(["type": "audio_stream_end"])
        
        stopSTTStreaming()
    }
    
    private func stopRecording(send: Bool) {
        levelTimer?.invalidate()
        levelTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        // Stop STT streaming if active
        if isSTTStreamingActive {
            if send {
                endSTTStreaming()
            } else {
                stopSTTStreaming()
            }
        }
        
        // Stop traditional recording
        audioRecorder?.stop()
        audioRecorder = nil
        
        try? AVAudioSession.sharedInstance().setActive(false)
        
        if send && !isSTTStreamingActive {
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
        
        let linearLevel = pow(10, level / 20)
        audioLevel = min(linearLevel * 3, 1.0)
        
        if linearLevel > silenceThreshold {
            hasDetectedSpeech = true
            lastSpeechTime = Date()
        }
        
        if hasDetectedSpeech {
            let silenceDuration = Date().timeIntervalSince(lastSpeechTime)
            let recordingDuration = Date().timeIntervalSince(recordingStartTime ?? Date())
            
            if silenceDuration >= silenceTimeout && recordingDuration >= minRecordingDuration {
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
            sendJSON(["type": "audio", "data": base64, "streaming": streamingEnabled])
            
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
        streamingResponse = ""
        messages.append(ChatMessage(isUser: true, text: text))
        sendJSON([
            "type": "text",
            "text": text,
            "wantsAudio": isConversationActive,
            "streaming": streamingEnabled
        ])
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
        streamingAudioPlayer = nil
        
        if isConversationActive {
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
