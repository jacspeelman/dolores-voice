// TTSManager.swift
// Dolores Voice - iOS Voice Assistant
//
// Text-to-Speech manager with ElevenLabs API support
// and AVSpeechSynthesizer fallback.

import AVFoundation
import Foundation

/// TTS provider options
enum TTSProvider {
    case elevenLabs
    case system
}

/// Configuration for ElevenLabs TTS
struct ElevenLabsConfig {
    /// API endpoint - TODO: Configure with actual endpoint
    let apiURL: URL = URL(string: "https://api.elevenlabs.io/v1/text-to-speech")!
    
    /// API key - TODO: Configure securely (use Keychain in production)
    var apiKey: String = "YOUR_ELEVENLABS_API_KEY"
    
    /// Voice ID to use
    var voiceId: String = "21m00Tcm4TlvDq8ikWAM" // Default: Rachel
    
    /// Model ID
    var modelId: String = "eleven_monolingual_v1"
    
    /// Voice settings
    var stability: Float = 0.5
    var similarityBoost: Float = 0.75
}

/// Errors that can occur during TTS
enum TTSError: LocalizedError {
    case noAudioData
    case apiError(String)
    case playbackFailed
    
    var errorDescription: String? {
        switch self {
        case .noAudioData:
            return "No audio data received"
        case .apiError(let message):
            return "TTS API error: \(message)"
        case .playbackFailed:
            return "Audio playback failed"
        }
    }
}

/// Manages Text-to-Speech functionality
@MainActor
class TTSManager: ObservableObject {
    // MARK: - Published Properties
    
    /// Whether currently speaking
    @Published var isSpeaking = false
    
    /// Current provider being used
    @Published var currentProvider: TTSProvider = .system
    
    // MARK: - Configuration
    
    /// ElevenLabs configuration
    var elevenLabsConfig = ElevenLabsConfig()
    
    /// Preferred provider (falls back to system if ElevenLabs fails)
    var preferredProvider: TTSProvider = .system // Default to system for PoC
    
    // MARK: - Private Properties
    
    /// System speech synthesizer
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    /// Audio player for ElevenLabs audio
    private var audioPlayer: AVAudioPlayer?
    
    /// Speech synthesizer delegate
    private var speechDelegate: SpeechDelegate?
    
    // MARK: - Initialization
    
    init() {
        speechDelegate = SpeechDelegate { [weak self] in
            Task { @MainActor in
                self?.isSpeaking = false
            }
        }
        speechSynthesizer.delegate = speechDelegate
    }
    
    // MARK: - Public Methods
    
    /// Speak text using the configured TTS provider
    func speak(_ text: String) async throws {
        guard !text.isEmpty else { return }
        
        // Stop any current speech
        stop()
        
        isSpeaking = true
        
        // Try preferred provider first
        do {
            switch preferredProvider {
            case .elevenLabs:
                try await speakWithElevenLabs(text)
                currentProvider = .elevenLabs
            case .system:
                try await speakWithSystem(text)
                currentProvider = .system
            }
        } catch {
            // Fallback to system if ElevenLabs fails
            if preferredProvider == .elevenLabs {
                print("⚠️ ElevenLabs failed, falling back to system TTS: \(error)")
                try await speakWithSystem(text)
                currentProvider = .system
            } else {
                isSpeaking = false
                throw error
            }
        }
    }
    
    /// Speak pre-fetched audio data (e.g., from server)
    func speakAudioData(_ data: Data) async throws {
        guard !data.isEmpty else {
            throw TTSError.noAudioData
        }
        
        stop()
        isSpeaking = true
        
        do {
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = AudioPlayerDelegate { [weak self] in
                Task { @MainActor in
                    self?.isSpeaking = false
                }
            }
            
            // Configure audio session
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            
            audioPlayer?.play()
            print("🔊 Playing audio data (\(data.count) bytes)")
        } catch {
            isSpeaking = false
            throw TTSError.playbackFailed
        }
    }
    
    /// Stop current speech
    func stop() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }
    
    // MARK: - Private Methods
    
    /// Speak using ElevenLabs API
    private func speakWithElevenLabs(_ text: String) async throws {
        let url = elevenLabsConfig.apiURL.appendingPathComponent(elevenLabsConfig.voiceId)
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(elevenLabsConfig.apiKey, forHTTPHeaderField: "xi-api-key")
        
        let body: [String: Any] = [
            "text": text,
            "model_id": elevenLabsConfig.modelId,
            "voice_settings": [
                "stability": elevenLabsConfig.stability,
                "similarity_boost": elevenLabsConfig.similarityBoost
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.apiError("Invalid response")
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TTSError.apiError("HTTP \(httpResponse.statusCode): \(errorMessage)")
        }
        
        // Play the received audio
        try await speakAudioData(data)
        print("🎙️ ElevenLabs TTS completed")
    }
    
    /// Speak using system AVSpeechSynthesizer
    private func speakWithSystem(_ text: String) async throws {
        let utterance = AVSpeechUtterance(string: text)
        
        // Configure voice - try to use a good quality voice
        if let voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Ava") {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = voice
        }
        
        // Configure speech parameters
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        // Configure audio session
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        
        speechSynthesizer.speak(utterance)
        print("🔊 System TTS started")
        
        // Wait for completion
        await withCheckedContinuation { continuation in
            speechDelegate?.onFinish = { [weak self] in
                self?.isSpeaking = false
                continuation.resume()
            }
        }
    }
}

// MARK: - Delegates

/// Delegate for AVSpeechSynthesizer
private class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    var onFinish: (() -> Void)?
    
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish?()
    }
}

/// Delegate for AVAudioPlayer
private class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}
