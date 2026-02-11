//
//  VoiceManager.swift
//  DoloresVoice
//
//  Pure voice mode - stream PCM audio to server, play TTS chunks
//  v2: No STT on device, all processing on server
//

import SwiftUI
import AVFoundation

/// Voice interaction state
enum VoiceState: String {
    case disconnected = "Niet verbonden"
    case connecting = "Verbinden..."
    case listening = "Luisteren..."
    case processing = "Denken..."
    case speaking = "Spreken..."
    case error = "Fout"
    
    var color: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .listening: return .blue
        case .processing: return .orange
        case .speaking: return .green
        case .error: return .red
        }
    }
    
    var icon: String {
        switch self {
        case .disconnected: return "wifi.slash"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .listening: return "waveform"
        case .processing: return "brain"
        case .speaking: return "speaker.wave.3.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

/// Streaming PCM audio player for server TTS chunks.
///
/// Accepts raw PCM S16LE, 16kHz, mono chunks and plays them via AVAudioEngine + AVAudioPlayerNode.
/// This is resilient to chunk boundaries and supports low-latency start with a small jitter buffer.
final class PCMStreamingAudioPlayer {
    private let queue = DispatchQueue(label: "pcm.streaming.player")

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    private let sampleRate: Double = 16_000
    private let channels: AVAudioChannelCount = 1

    private lazy var format: AVAudioFormat = {
        // Non-interleaved is the most common representation for AVAudioPCMBuffer.
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: sampleRate,
                      channels: channels,
                      interleaved: false)!
    }()

    private var audioQueue: [Data] = []
    private var isEngineRunning = false
    private var isPlaying = false

    private var scheduledBuffers = 0
    private var onComplete: (() -> Void)?
    private var finalizing = false

    // Jitter buffer: wait until we have ~250ms before starting playback.
    private let startBufferSeconds: Double = 0.25

    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    func addChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.audioQueue.append(data)
            self.finalizing = false
            self.onComplete = nil
            self.ensureStartedIfReady()
            self.scheduleMoreIfNeeded()
        }
    }

    func finalize(onComplete: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.finalizing = true
            self.onComplete = onComplete
            self.maybeComplete()
        }
    }

    func stop() {
        queue.sync {
            audioQueue.removeAll()
            finalizing = false
            onComplete = nil
            scheduledBuffers = 0
            isPlaying = false

            playerNode.stop()
            engine.stop()
            isEngineRunning = false
        }
    }

    // MARK: - Internals

    private func totalQueuedSeconds() -> Double {
        let bytes = audioQueue.reduce(0) { $0 + $1.count }
        let frames = Double(bytes / 2) // 2 bytes per Int16 sample (mono)
        return frames / sampleRate
    }

    private func ensureEngineRunning() throws {
        guard !isEngineRunning else { return }
        try engine.start()
        isEngineRunning = true
    }

    private func ensureStartedIfReady() {
        do {
            try ensureEngineRunning()
        } catch {
            print("⚠️ PCM engine start failed: \(error)")
            return
        }

        guard !isPlaying else { return }
        guard totalQueuedSeconds() >= startBufferSeconds else { return }

        playerNode.play()
        isPlaying = true
    }

    private func scheduleMoreIfNeeded() {
        // Keep a small number of buffers scheduled ahead to avoid runaway scheduling.
        let maxScheduledAhead = 8
        while scheduledBuffers < maxScheduledAhead, !audioQueue.isEmpty {
            let chunk = audioQueue.removeFirst()
            guard let pcmBuffer = makePCMBuffer(from: chunk) else { continue }

            scheduledBuffers += 1
            playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                    self.ensureStartedIfReady()
                    self.scheduleMoreIfNeeded()
                    self.maybeComplete()
                }
            }
        }
    }

    private func makePCMBuffer(from data: Data) -> AVAudioPCMBuffer? {
        // Data is PCM S16LE mono.
        let alignedCount = data.count - (data.count % 2)
        guard alignedCount > 0 else { return nil }

        let frameCount = AVAudioFrameCount(alignedCount / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        data.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            if let dst = buffer.int16ChannelData {
                memcpy(dst[0], src, alignedCount)
            }
        }

        return buffer
    }

    private func maybeComplete() {
        guard finalizing else { return }
        guard audioQueue.isEmpty, scheduledBuffers == 0 else { return }

        let cb = onComplete
        onComplete = nil
        finalizing = false

        if cb != nil {
            DispatchQueue.main.async {
                cb?()
            }
        }
    }
}

@MainActor
class VoiceManager: ObservableObject {
    // MARK: - Configuration
    
    private let serverURL = URL(string: "ws://192.168.1.214:8765")!
    private let maxReconnectAttempts = 5
    
    // Audio settings (match server expectations)
    private let sampleRate: Double = 16000
    private let audioChunkIntervalMs: Double = 100  // Send chunks every 100ms
    
    // Barge-in settings
    // NOTE: Temporarily disabled by making detection extremely conservative.
    // Without speaker verification / robust AEC, the monitor can trigger on our own TTS audio.
    private let bargeInThreshold: Float = 0.25
    private let bargeInDurationMs: Double = 1200
    
    // MARK: - Published State
    
    @Published var state: VoiceState = .disconnected
    @Published var errorMessage: String?
    @Published var isConnected: Bool = false
    @Published var audioLevel: Float = 0.0
    
    // UI animation properties
    @Published var spinnerRotation: Double = 0.0
    @Published var waveformScale: CGFloat = 1.0
    
    // MARK: - Private Properties
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempts = 0
    private var reconnectTask: Task<Void, Never>?
    
    // Audio recording (AVAudioEngine for real-time PCM streaming)
    private var audioEngine: AVAudioEngine?
    private var pcmBuffer: Data = Data()
    private var audioChunkTimer: Timer?
    private var isRecording = false
    
    // Audio playback
    private var streamingAudioPlayer: PCMStreamingAudioPlayer?
    
    // Barge-in monitoring
    private var bargeInMonitor: AVAudioRecorder?
    private var bargeInTimer: Timer?
    private var bargeInDetectionStartTime: Date?
    
    // Animation timers
    private var spinnerTimer: Timer?
    private var waveformTimer: Timer?
    
    // MARK: - Initialization
    
    init() {
        setupAudioSession()
    }
    
    deinit {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            print("✅ Audio session configured: playAndRecord, voiceChat mode")
        } catch {
            print("⚠️ Audio session setup failed: \(error)")
            errorMessage = "Audio setup mislukt"
        }
    }
    
    // MARK: - Permissions
    
    func checkPermissions() {
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted {
                errorMessage = "Microfoon toegang vereist"
            }
        }
    }
    
    // MARK: - WebSocket Connection
    
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
                // Send start_conversation to begin
                sendJSON(["type": "start_conversation"])
                isConnected = true
                state = .listening
                reconnectAttempts = 0
                startRecording()
            }
        }
    }
    
    func disconnect() {
        stopRecording()
        stopBargeInMonitoring()
        streamingAudioPlayer?.stop()
        reconnectTask?.cancel()
        
        // Send end_conversation before closing
        if isConnected {
            sendJSON(["type": "end_conversation"])
        }
        
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
    
    // MARK: - WebSocket Communication
    
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
        stopRecording()
        stopBargeInMonitoring()
        streamingAudioPlayer?.stop()
        scheduleReconnect()
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        
        switch type {
        case "state":
            // Server tells us the current state
            if let stateString = json["state"] as? String {
                switch stateString {
                case "listening":
                    state = .listening
                    stopProcessingAnimation()
                    stopSpeakingAnimation()
                    // Prevent echo-loop: only record when server is listening.
                    // Add a short tail so we don't immediately re-capture our own TTS.
                    stopRecording()
                    stopBargeInMonitoring()
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(350))
                        await MainActor.run {
                            self?.startRecording()
                        }
                    }
                case "processing":
                    state = .processing
                    startProcessingAnimation()
                    stopSpeakingAnimation()
                    // Don't record while server is processing.
                    stopRecording()
                    stopBargeInMonitoring()
                case "speaking":
                    state = .speaking
                    stopProcessingAnimation()
                    startSpeakingAnimation()
                    // Don't record while speaking (avoids self-transcription loops).
                    stopRecording()
                    stopBargeInMonitoring()
                default:
                    break
                }
            }
            
        case "audio":
            // Single audio chunk (TTS)
            // Expected protocol: {type:'audio', format:'pcm_s16le', sampleRate:16000, channels:1, data:base64}
            let format = (json["format"] as? String) ?? ""
            let sr = (json["sampleRate"] as? Double) ?? Double(json["sampleRate"] as? Int ?? 0)
            let ch = (json["channels"] as? Int) ?? 0

            guard format == "pcm_s16le", Int(sr) == 16000, ch == 1 else {
                // Ignore unknown/legacy formats (e.g., mp3 chunks)
                return
            }

            if let base64 = json["data"] as? String,
               let audioData = Data(base64Encoded: base64) {
                playAudioChunk(audioData)
            }
            
        case "audio_end":
            // Server finished speaking.
            // Send playback_done immediately (best-effort) so server can resume STT.
            // We still finalize the local player and update UI when audio really drains.
            sendJSON(["type": "playback_done"])

            streamingAudioPlayer?.finalize { [weak self] in
                Task { @MainActor in
                    self?.onSpeakingFinished()
                }
            }
            
        case "transcript":
            // User transcript (for logging only, don't display)
            if let transcript = json["text"] as? String {
                print("📝 User said: \(transcript)")
            }
            
        case "error":
            if let error = json["error"] as? String {
                errorMessage = error
                state = .error
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    errorMessage = nil
                    if isConnected {
                        state = .listening
                    }
                }
            }
            
        default:
            break
        }
    }
    
    // MARK: - Audio Recording (PCM Streaming)
    
    private func startRecording() {
        guard !isRecording, isConnected else { return }
        
        stopRecording()
        isRecording = true
        pcmBuffer = Data()
        
        do {
            audioEngine = AVAudioEngine()
            guard let engine = audioEngine else { return }
            
            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            // Target format: 16kHz, 16-bit mono PCM
            guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                   sampleRate: sampleRate,
                                                   channels: 1,
                                                   interleaved: true) else {
                print("⚠️ Failed to create target audio format")
                return
            }
            
            // Audio converter
            guard let converter = AVAudioConverter(from: recordingFormat, to: targetFormat) else {
                print("⚠️ Failed to create audio converter")
                return
            }
            
            // Install tap to capture audio
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, time in
                guard let self = self, self.isRecording else { return }
                
                // Convert to 16kHz 16-bit PCM
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * self.sampleRate / recordingFormat.sampleRate)
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
            
            print("✅ Recording started (PCM streaming)")
            
        } catch {
            print("⚠️ Recording failed: \(error)")
            errorMessage = "Opname mislukt"
            isRecording = false
        }
    }
    
    private func stopRecording() {
        guard isRecording else { return }
        
        isRecording = false
        
        audioChunkTimer?.invalidate()
        audioChunkTimer = nil
        
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        
        pcmBuffer = Data()
        audioLevel = 0.0
        
        print("🛑 Recording stopped")
    }
    
    private func sendAudioChunk() {
        guard isRecording, !pcmBuffer.isEmpty, isConnected else { return }
        
        let chunk = pcmBuffer
        pcmBuffer = Data()
        
        let base64 = chunk.base64EncodedString()
        sendJSON(["type": "audio", "data": base64])
    }
    
    // MARK: - Audio Playback
    
    private func playAudioChunk(_ data: Data) {
        if streamingAudioPlayer == nil {
            streamingAudioPlayer = PCMStreamingAudioPlayer()
        }
        streamingAudioPlayer?.addChunk(data)
    }
    
    private func onSpeakingFinished() {
        stopBargeInMonitoring()
        stopSpeakingAnimation()
        streamingAudioPlayer = nil
        
        // Resume listening
        if isConnected {
            state = .listening
        }
    }
    
    // MARK: - Barge-in Detection
    
    private func startBargeInMonitoring() {
        stopBargeInMonitoring()
        bargeInDetectionStartTime = nil
        
        do {
            // Use a dummy AVAudioRecorder for level monitoring during playback
            let tempDir = FileManager.default.temporaryDirectory
            let bargeInURL = tempDir.appendingPathComponent("bargein_monitor.m4a")
            
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
            ]
            
            try? FileManager.default.removeItem(at: bargeInURL)
            
            bargeInMonitor = try AVAudioRecorder(url: bargeInURL, settings: settings)
            bargeInMonitor?.isMeteringEnabled = true
            bargeInMonitor?.record()
            
            // Poll audio level at ~20Hz
            bargeInTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.checkBargeIn()
                }
            }
            
            print("🎙️ Barge-in monitoring started")
            
        } catch {
            print("⚠️ Barge-in monitoring failed: \(error)")
        }
    }
    
    private func stopBargeInMonitoring() {
        bargeInTimer?.invalidate()
        bargeInTimer = nil
        bargeInMonitor?.stop()
        bargeInMonitor = nil
        bargeInDetectionStartTime = nil
    }
    
    private func checkBargeIn() {
        guard state == .speaking, let monitor = bargeInMonitor else { return }
        
        monitor.updateMeters()
        let power = monitor.averagePower(forChannel: 0)
        let linear = pow(10, power / 20)
        
        if linear > bargeInThreshold {
            if bargeInDetectionStartTime == nil {
                bargeInDetectionStartTime = Date()
            } else if let startTime = bargeInDetectionStartTime {
                let duration = Date().timeIntervalSince(startTime) * 1000  // ms
                if duration >= bargeInDurationMs {
                    performBargeIn()
                }
            }
        } else {
            bargeInDetectionStartTime = nil
        }
    }
    
    private func performBargeIn() {
        print("🎤 Barge-in triggered!")
        
        stopBargeInMonitoring()
        
        // Stop audio playback
        streamingAudioPlayer?.stop()
        streamingAudioPlayer = nil
        
        // Send interrupt to server
        sendJSON(["type": "interrupt"])
        
        // Return to listening
        state = .listening
        
        // Short delay before resuming recording
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if isConnected && state == .listening {
                startRecording()
            }
        }
    }
    
    // MARK: - UI Animations
    
    private func startProcessingAnimation() {
        stopProcessingAnimation()
        spinnerRotation = 0.0
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.spinnerRotation += 3.0
                if (self?.spinnerRotation ?? 0) >= 360 {
                    self?.spinnerRotation = 0
                }
            }
        }
    }
    
    private func stopProcessingAnimation() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
    }
    
    private func startSpeakingAnimation() {
        stopSpeakingAnimation()
        waveformScale = 1.0
        var direction: CGFloat = 1.0
        waveformTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.waveformScale += 0.05 * direction
                if self.waveformScale >= 1.2 {
                    direction = -1.0
                } else if self.waveformScale <= 0.8 {
                    direction = 1.0
                }
            }
        }
    }
    
    private func stopSpeakingAnimation() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        waveformScale = 1.0
    }
}
