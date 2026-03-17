//
//  RealtimeVoiceManager.swift
//  DoloresVoice
//
//  OpenAI Realtime API mode — direct WebRTC connection to OpenAI.
//  No Deepgram, no ElevenLabs, no audio proxying.
//  Server only mints an ephemeral token.
//

import SwiftUI
import AVFoundation
import WebRTC

// MARK: - Data Models

struct RealtimeSessionResponse: Decodable {
    let id: String?
    let client_secret: ClientSecret?

    struct ClientSecret: Decodable {
        let value: String
    }
}

struct RealtimeEvent: Decodable {
    let type: String
    let transcript: String?
    let error: RealtimeError?
    let delta: String?

    struct RealtimeError: Decodable {
        let message: String?
        let code: String?
    }
}

// MARK: - Transcript Model

struct TranscriptMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date

    enum Role {
        case user
        case assistant
    }
}

// MARK: - RealtimeVoiceManager

@MainActor
class RealtimeVoiceManager: ObservableObject {

    // MARK: - Configuration

    private let serverBaseURL = "http://192.168.1.66:8765"
    private let defaultVoice = "marin"
    private let defaultInstructions = "Spreek natuurlijk Nederlands met een neutraal accent. Praat helder, vriendelijk en beknopt. Gebruik alleen Nederlands tenzij de gebruiker expliciet om Engels vraagt."

    // MARK: - Published State

    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var isSpeaking = false        // AI is speaking
    @Published var isUserSpeaking = false    // User is speaking
    @Published var errorMessage: String?
    @Published var transcript: [TranscriptMessage] = []

    // UI animation
    @Published var state: VoiceState = .disconnected
    @Published var spinnerRotation: Double = 0.0
    @Published var waveformScale: CGFloat = 1.0
    @Published var listeningWaveformScale: CGFloat = 1.0
    @Published var audioLevel: Float = 0.0

    // MARK: - WebRTC Properties

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )
    }()

    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var localAudioTrack: RTCAudioTrack?

    // Animation timers
    private var spinnerTimer: Timer?
    private var waveformTimer: Timer?
    private var listeningWaveformTimer: Timer?

    // MARK: - Audio Session

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            print("✅ [Realtime] Audio session configured")
        } catch {
            print("⚠️ [Realtime] Audio session setup failed: \(error)")
            errorMessage = "Audio setup mislukt"
        }
    }

    // MARK: - Connect

    func connect(voice: String? = nil, instructions: String? = nil) {
        guard !isConnecting, !isConnected else { return }
        isConnecting = true
        state = .connecting
        errorMessage = nil

        setupAudioSession()

        Task {
            do {
                let selectedVoice = voice ?? defaultVoice
                let selectedInstructions = instructions ?? defaultInstructions

                // Step 1: Get ephemeral token from our backend
                print("🔑 [Realtime] Fetching ephemeral token...")
                let ephemeralKey = try await fetchEphemeralToken(
                    voice: selectedVoice,
                    instructions: selectedInstructions
                )

                // Step 2: Create RTCPeerConnection
                print("🔗 [Realtime] Creating peer connection...")
                let config = RTCConfiguration()
                config.sdpSemantics = .unifiedPlan
                // ICE servers not needed — OpenAI uses TURN internally

                let constraints = RTCMediaConstraints(
                    mandatoryConstraints: nil,
                    optionalConstraints: nil
                )

                let pc = RealtimeVoiceManager.factory.peerConnection(
                    with: config,
                    constraints: constraints,
                    delegate: nil
                )
                guard let pc = pc else {
                    throw RealtimeError.connectionFailed("Failed to create peer connection")
                }
                self.peerConnection = pc

                // Set delegate via helper
                let delegateHandler = PeerConnectionDelegate(manager: self)
                pc.delegate = delegateHandler
                // Keep strong ref
                self.peerConnectionDelegate = delegateHandler

                // Step 3: Add local audio track (microphone)
                let audioConstraints = RTCMediaConstraints(
                    mandatoryConstraints: nil,
                    optionalConstraints: nil
                )
                let audioSource = RealtimeVoiceManager.factory.audioSource(with: audioConstraints)
                let audioTrack = RealtimeVoiceManager.factory.audioTrack(with: audioSource, trackId: "mic-track")
                audioTrack.isEnabled = true
                self.localAudioTrack = audioTrack

                pc.add(audioTrack, streamIds: ["mic-stream"])

                // Step 4: Create data channel for events
                let dcConfig = RTCDataChannelConfiguration()
                dcConfig.isOrdered = true
                guard let dc = pc.dataChannel(forLabel: "oai-events", configuration: dcConfig) else {
                    throw RealtimeError.connectionFailed("Failed to create data channel")
                }
                self.dataChannel = dc

                let dcDelegate = DataChannelDelegate(manager: self)
                dc.delegate = dcDelegate
                self.dataChannelDelegate = dcDelegate

                // Step 5: Create SDP offer
                print("📡 [Realtime] Creating SDP offer...")
                let offerConstraints = RTCMediaConstraints(
                    mandatoryConstraints: [
                        kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue
                    ],
                    optionalConstraints: nil
                )

                let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
                    pc.offer(for: offerConstraints) { sdp, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else if let sdp = sdp {
                            continuation.resume(returning: sdp)
                        } else {
                            continuation.resume(throwing: RealtimeError.connectionFailed("No SDP offer"))
                        }
                    }
                }

                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    pc.setLocalDescription(offer) { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }

                // Step 6: Send SDP to OpenAI, get answer
                print("📡 [Realtime] Local SDP set, sending offer to OpenAI...")
                print("📡 [Realtime] SDP offer length: \(offer.sdp.count) chars")
                let answerSdp = try await sendOfferToOpenAI(
                    sdp: offer.sdp,
                    ephemeralKey: ephemeralKey
                )

                let answer = RTCSessionDescription(type: .answer, sdp: answerSdp)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    pc.setRemoteDescription(answer) { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }

                print("✅ [Realtime] WebRTC connection established!")
                isConnected = true
                isConnecting = false
                state = .listening
                startListeningAnimation()

            } catch {
                print("❌ [Realtime] Connection failed: \(error)")
                print("❌ [Realtime] Error type: \(type(of: error))")
                print("❌ [Realtime] Error details: \(String(describing: error))")
                if let urlError = error as? URLError {
                    print("❌ [Realtime] URLError code: \(urlError.code.rawValue) - \(urlError.localizedDescription)")
                }
                errorMessage = "Verbinding mislukt: \(error.localizedDescription)"
                isConnecting = false
                state = .error
                cleanup()
            }
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        cleanup()
        state = .disconnected
        isConnected = false
        isConnecting = false
        isSpeaking = false
        isUserSpeaking = false
        transcript = []
        stopAllAnimations()
    }

    func reconnect() {
        disconnect()
        connect()
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

    // MARK: - Send event via data channel

    func sendEvent(_ event: [String: Any]) {
        guard let dc = dataChannel, dc.readyState == .open else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        let buffer = RTCDataBuffer(data: data, isBinary: false)
        dc.sendData(buffer)
    }

    /// Send a response.create to trigger the AI to respond
    func triggerResponse() {
        sendEvent(["type": "response.create"])
    }

    // MARK: - Private: Network

    private func fetchEphemeralToken(voice: String, instructions: String) async throws -> String {
        guard let url = URL(string: "\(serverBaseURL)/realtime-session") else {
            throw RealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: String] = [
            "voice": voice,
            "instructions": instructions
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw RealtimeError.serverError("Server returned \(statusCode): \(body)")
        }

        let session = try JSONDecoder().decode(RealtimeSessionResponse.self, from: data)
        guard let key = session.client_secret?.value else {
            throw RealtimeError.serverError("No client_secret in response")
        }

        return key
    }

    private func sendOfferToOpenAI(sdp: String, ephemeralKey: String) async throws -> String {
        guard let url = URL(string: "https://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview") else {
            throw RealtimeError.invalidURL
        }

        print("📡 [Realtime] POST to OpenAI Realtime API...")
        print("📡 [Realtime] Ephemeral key prefix: \(String(ephemeralKey.prefix(20)))...")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = sdp.data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("📡 [Realtime] OpenAI response status: \(statusCode)")

        guard let httpResponse = response as? HTTPURLResponse, (200...201).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            print("❌ [Realtime] OpenAI error body: \(body)")
            throw RealtimeError.serverError("OpenAI returned \(statusCode): \(body)")
        }

        guard let answerSdp = String(data: data, encoding: .utf8) else {
            throw RealtimeError.serverError("Invalid SDP answer from OpenAI")
        }

        print("✅ [Realtime] Got SDP answer (\(answerSdp.count) chars)")
        return answerSdp
    }

    // MARK: - Private: Cleanup

    private func cleanup() {
        localAudioTrack?.isEnabled = false
        localAudioTrack = nil
        dataChannel?.close()
        dataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        peerConnectionDelegate = nil
        dataChannelDelegate = nil
    }

    // MARK: - Handle Data Channel Events

    fileprivate nonisolated func handleRealtimeEvent(_ data: Data) {
        guard let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data) else {
            // Try to at least get the type for logging
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String {
                print("📨 [Realtime] Event: \(type)")
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            switch event.type {
            case "session.created":
                print("✅ [Realtime] Session created")

            case "session.updated":
                print("✅ [Realtime] Session updated")

            case "conversation.item.input_audio_transcription.completed":
                if let text = event.transcript, !text.isEmpty {
                    print("📝 [Realtime] User: \(text)")
                    transcript.append(TranscriptMessage(role: .user, text: text, timestamp: Date()))
                }

            case "response.audio_transcript.done":
                if let text = event.transcript, !text.isEmpty {
                    print("📝 [Realtime] Assistant: \(text)")
                    transcript.append(TranscriptMessage(role: .assistant, text: text, timestamp: Date()))
                }

            case "response.audio_transcript.delta":
                // Partial transcript from assistant — could show live if desired
                break

            case "input_audio_buffer.speech_started":
                print("🎙️ [Realtime] User speaking...")
                isUserSpeaking = true
                state = .listening
                audioLevel = 0.5
                startListeningAnimation()
                stopSpeakingAnimation()

            case "input_audio_buffer.speech_stopped":
                print("🎙️ [Realtime] User stopped speaking")
                isUserSpeaking = false
                audioLevel = 0.0
                state = .processing
                stopListeningAnimation()
                startProcessingAnimation()

            case "response.created", "response.output_item.added":
                // Response generation started
                break

            case "response.audio.delta":
                // Audio chunk being sent via WebRTC track (not data channel)
                // The remote audio track handles playback automatically
                break

            case "response.audio.done":
                // AI finished speaking
                isSpeaking = false
                state = .listening
                stopSpeakingAnimation()
                startListeningAnimation()

            case "response.done":
                // Full response complete
                isSpeaking = false
                state = .listening
                stopSpeakingAnimation()
                stopProcessingAnimation()
                startListeningAnimation()

            case "output_audio_buffer.audio_started":
                // AI starts speaking
                isSpeaking = true
                state = .speaking
                stopProcessingAnimation()
                startSpeakingAnimation()

            case "output_audio_buffer.audio_stopped":
                // AI stops speaking
                isSpeaking = false
                state = .listening
                stopSpeakingAnimation()
                startListeningAnimation()

            case "error":
                let msg = event.error?.message ?? "Onbekende fout"
                print("❌ [Realtime] Error: \(msg)")
                errorMessage = msg
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    errorMessage = nil
                }

            default:
                print("📨 [Realtime] Event: \(event.type)")
            }
        }
    }

    // MARK: - Delegate Refs (prevent deallocation)

    private var peerConnectionDelegate: PeerConnectionDelegate?
    private var dataChannelDelegate: DataChannelDelegate?

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
                if self.waveformScale >= 1.2 { direction = -1.0 }
                else if self.waveformScale <= 0.8 { direction = 1.0 }
            }
        }
    }

    private func stopSpeakingAnimation() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        waveformScale = 1.0
    }

    private func startListeningAnimation() {
        guard listeningWaveformTimer == nil else { return }
        listeningWaveformScale = 1.0
        var direction: CGFloat = 1.0
        listeningWaveformTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.listeningWaveformScale += 0.05 * direction
                if self.listeningWaveformScale >= 1.2 { direction = -1.0 }
                else if self.listeningWaveformScale <= 0.8 { direction = 1.0 }
            }
        }
    }

    private func stopListeningAnimation() {
        listeningWaveformTimer?.invalidate()
        listeningWaveformTimer = nil
        listeningWaveformScale = 1.0
    }

    private func stopAllAnimations() {
        stopProcessingAnimation()
        stopSpeakingAnimation()
        stopListeningAnimation()
    }
}

// MARK: - Errors

enum RealtimeError: LocalizedError {
    case invalidURL
    case connectionFailed(String)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Ongeldige URL"
        case .connectionFailed(let msg): return "Verbinding mislukt: \(msg)"
        case .serverError(let msg): return "Serverfout: \(msg)"
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

private class PeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate {
    weak var manager: RealtimeVoiceManager?

    init(manager: RealtimeVoiceManager) {
        self.manager = manager
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("📡 [Realtime] Signaling state: \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("📡 [Realtime] Remote stream added with \(stream.audioTracks.count) audio track(s)")
        // Remote audio plays automatically through the device speaker
        // AVAudioSession is already configured for playAndRecord
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("📡 [Realtime] Remote stream removed")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("📡 [Realtime] Negotiation needed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("📡 [Realtime] ICE connection state: \(newState.rawValue)")
        Task { @MainActor [weak self] in
            switch newState {
            case .connected, .completed:
                self?.manager?.isConnected = true
            case .disconnected, .failed, .closed:
                self?.manager?.isConnected = false
                self?.manager?.state = .disconnected
                self?.manager?.errorMessage = "Verbinding verloren"
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("📡 [Realtime] ICE gathering state: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        // ICE candidates are handled automatically for the OpenAI Realtime API
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("📡 [Realtime] Data channel opened (remote): \(dataChannel.label)")
    }
}

// MARK: - RTCDataChannelDelegate

private class DataChannelDelegate: NSObject, RTCDataChannelDelegate {
    weak var manager: RealtimeVoiceManager?

    init(manager: RealtimeVoiceManager) {
        self.manager = manager
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("📡 [Realtime] Data channel state: \(dataChannel.readyState.rawValue)")
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        manager?.handleRealtimeEvent(buffer.data)
    }
}
