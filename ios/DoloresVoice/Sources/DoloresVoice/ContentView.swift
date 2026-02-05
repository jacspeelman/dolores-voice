// ContentView.swift
// Dolores Voice - iOS Voice Assistant
//
// Main UI view with push-to-talk functionality,
// status indicators, and waveform visualization.

import SwiftUI

/// Application state for voice interaction
enum VoiceState: String {
    case idle = "Ready"
    case listening = "Listening..."
    case processing = "Processing..."
    case speaking = "Speaking..."
    case error = "Error"
    
    /// Color associated with each state
    var color: Color {
        switch self {
        case .idle: return .gray
        case .listening: return .red
        case .processing: return .orange
        case .speaking: return .green
        case .error: return .red
        }
    }
    
    /// SF Symbol icon for each state
    var icon: String {
        switch self {
        case .idle: return "mic.circle"
        case .listening: return "mic.circle.fill"
        case .processing: return "brain"
        case .speaking: return "speaker.wave.3.fill"
        case .error: return "exclamationmark.triangle"
        }
    }
}

/// Main content view
struct ContentView: View {
    // MARK: - Environment Objects
    
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var webSocketManager: WebSocketManager
    @EnvironmentObject var ttsManager: TTSManager
    
    // MARK: - State
    
    @State private var voiceState: VoiceState = .idle
    @State private var isPressed = false
    @State private var audioLevels: [CGFloat] = Array(repeating: 0.1, count: 20)
    @State private var errorMessage: String?
    
    // MARK: - Body
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.black, Color(white: 0.1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 40) {
                Spacer()
                
                // Title
                Text("Dolores")
                    .font(.system(size: 48, weight: .thin, design: .rounded))
                    .foregroundColor(.white)
                
                // Status indicator
                statusIndicator
                
                // Waveform visualization
                waveformView
                    .frame(height: 100)
                    .padding(.horizontal, 40)
                
                // Error message if present
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                }
                
                Spacer()
                
                // Push-to-talk button
                pushToTalkButton
                    .padding(.bottom, 60)
                
                // Connection status
                connectionStatus
                    .padding(.bottom, 20)
            }
        }
        .onReceive(audioManager.$audioLevel) { level in
            updateWaveform(with: level)
        }
        .onReceive(ttsManager.$isSpeaking) { speaking in
            if speaking {
                voiceState = .speaking
            } else if voiceState == .speaking {
                voiceState = .idle
            }
        }
    }
    
    // MARK: - Subviews
    
    /// Status indicator showing current voice state
    private var statusIndicator: some View {
        HStack(spacing: 12) {
            Image(systemName: voiceState.icon)
                .font(.title2)
                .foregroundColor(voiceState.color)
                .symbolEffect(.pulse, isActive: voiceState == .listening || voiceState == .processing)
            
            Text(voiceState.rawValue)
                .font(.headline)
                .foregroundColor(voiceState.color)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(voiceState.color.opacity(0.2))
        )
    }
    
    /// Waveform visualization placeholder
    private var waveformView: some View {
        HStack(spacing: 4) {
            ForEach(0..<audioLevels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        voiceState == .listening
                            ? Color.red.opacity(0.8)
                            : Color.gray.opacity(0.4)
                    )
                    .frame(width: 8, height: audioLevels[index] * 80)
                    .animation(.easeInOut(duration: 0.1), value: audioLevels[index])
            }
        }
    }
    
    /// Push-to-talk button
    private var pushToTalkButton: some View {
        Button(action: {}) {
            ZStack {
                // Outer ring
                Circle()
                    .stroke(
                        isPressed ? Color.red : Color.gray.opacity(0.5),
                        lineWidth: 4
                    )
                    .frame(width: 120, height: 120)
                    .scaleEffect(isPressed ? 1.1 : 1.0)
                
                // Inner circle
                Circle()
                    .fill(
                        isPressed
                            ? Color.red
                            : Color.gray.opacity(0.3)
                    )
                    .frame(width: 100, height: 100)
                
                // Mic icon
                Image(systemName: isPressed ? "mic.fill" : "mic")
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        startRecording()
                    }
                }
                .onEnded { _ in
                    stopRecording()
                }
        )
        .animation(.spring(response: 0.3), value: isPressed)
    }
    
    /// Connection status indicator
    private var connectionStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(webSocketManager.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            
            Text(webSocketManager.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
    
    // MARK: - Private Methods
    
    /// Start recording audio
    private func startRecording() {
        isPressed = true
        voiceState = .listening
        errorMessage = nil
        
        Task {
            do {
                try await audioManager.startRecording()
            } catch {
                errorMessage = error.localizedDescription
                voiceState = .error
            }
        }
        
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }
    
    /// Stop recording and process
    private func stopRecording() {
        isPressed = false
        
        Task {
            do {
                let audioData = try await audioManager.stopRecording()
                voiceState = .processing
                
                // Send to server via WebSocket
                if webSocketManager.isConnected {
                    try await webSocketManager.sendAudio(audioData)
                } else {
                    // Fallback: just show we captured audio
                    print("📦 Captured \(audioData.count) bytes of audio")
                    
                    // Simulate response for demo
                    try await Task.sleep(for: .seconds(1))
                    voiceState = .idle
                }
            } catch {
                errorMessage = error.localizedDescription
                voiceState = .error
                
                // Reset after delay
                try? await Task.sleep(for: .seconds(2))
                voiceState = .idle
            }
        }
        
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
    
    /// Update waveform visualization with audio level
    private func updateWaveform(with level: Float) {
        guard voiceState == .listening else {
            // Reset to idle state
            withAnimation {
                audioLevels = Array(repeating: 0.1, count: 20)
            }
            return
        }
        
        // Shift existing levels
        audioLevels.removeFirst()
        
        // Add new level (normalized 0-1)
        let normalizedLevel = CGFloat(min(max(level, 0), 1))
        audioLevels.append(normalizedLevel + 0.1) // Minimum height
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AudioManager())
        .environmentObject(WebSocketManager())
        .environmentObject(TTSManager())
}
