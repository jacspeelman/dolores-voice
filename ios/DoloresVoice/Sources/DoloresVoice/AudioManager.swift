// AudioManager.swift
// Dolores Voice - iOS Voice Assistant
//
// Manages audio capture using AVAudioEngine.
// Handles microphone permission, recording, and audio level monitoring.

import AVFoundation
import Combine

/// Errors that can occur during audio operations
enum AudioError: LocalizedError {
    case permissionDenied
    case engineStartFailed
    case noAudioData
    case encodingFailed
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access denied. Please enable in Settings."
        case .engineStartFailed:
            return "Failed to start audio engine."
        case .noAudioData:
            return "No audio data captured."
        case .encodingFailed:
            return "Failed to encode audio data."
        }
    }
}

/// Manages audio capture and processing
@MainActor
class AudioManager: ObservableObject {
    // MARK: - Published Properties
    
    /// Current audio level (0-1) for visualization
    @Published var audioLevel: Float = 0
    
    /// Whether recording is currently active
    @Published var isRecording = false
    
    /// Whether microphone permission is granted
    @Published var hasPermission = false
    
    // MARK: - Private Properties
    
    /// Audio engine for capture
    private var audioEngine: AVAudioEngine?
    
    /// Buffer to store recorded audio
    private var audioBuffer: AVAudioPCMBuffer?
    
    /// Collected audio data during recording
    private var recordedData = Data()
    
    /// Audio format for recording (16kHz mono, suitable for speech)
    private let recordingFormat: AVAudioFormat? = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
    }()
    
    // MARK: - Initialization
    
    init() {
        // Check initial permission state
        checkPermission()
    }
    
    // MARK: - Public Methods
    
    /// Request microphone permission
    func requestPermission() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        hasPermission = granted
        
        if granted {
            print("🎤 Microphone permission granted")
        } else {
            print("⚠️ Microphone permission denied")
        }
    }
    
    /// Start recording audio
    func startRecording() async throws {
        guard hasPermission else {
            throw AudioError.permissionDenied
        }
        
        // Configure audio session
        try configureAudioSession()
        
        // Reset state
        recordedData = Data()
        
        // Create and configure audio engine
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine,
              let recordingFormat = recordingFormat else {
            throw AudioError.engineStartFailed
        }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            Task { @MainActor in
                self?.processAudioBuffer(buffer)
            }
        }
        
        // Start engine
        do {
            try audioEngine.start()
            isRecording = true
            print("🎙️ Recording started")
        } catch {
            throw AudioError.engineStartFailed
        }
    }
    
    /// Stop recording and return captured audio data
    func stopRecording() async throws -> Data {
        guard let audioEngine = audioEngine else {
            throw AudioError.noAudioData
        }
        
        // Stop engine
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        
        isRecording = false
        audioLevel = 0
        
        print("🛑 Recording stopped, captured \(recordedData.count) bytes")
        
        guard !recordedData.isEmpty else {
            throw AudioError.noAudioData
        }
        
        // Return a copy and reset
        let capturedData = recordedData
        recordedData = Data()
        self.audioEngine = nil
        
        return capturedData
    }
    
    // MARK: - Private Methods
    
    /// Check current permission state
    private func checkPermission() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            hasPermission = true
        case .denied:
            hasPermission = false
        case .undetermined:
            hasPermission = false
        @unknown default:
            hasPermission = false
        }
    }
    
    /// Configure audio session for recording
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
    }
    
    /// Process incoming audio buffer
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        // Calculate audio level for visualization
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = buffer.frameLength
        
        var sum: Float = 0
        for i in 0..<Int(frames) {
            sum += abs(channelData[i])
        }
        let average = sum / Float(frames)
        
        // Smooth the level change
        let smoothedLevel = audioLevel * 0.7 + average * 0.3 * 3 // Amplify for visibility
        audioLevel = min(smoothedLevel, 1.0)
        
        // Convert buffer to data
        if let data = bufferToData(buffer) {
            recordedData.append(data)
        }
    }
    
    /// Convert audio buffer to raw data
    private func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }
        
        let frames = Int(buffer.frameLength)
        let data = Data(bytes: channelData[0], count: frames * MemoryLayout<Float>.size)
        
        return data
    }
}
