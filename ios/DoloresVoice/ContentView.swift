//
//  ContentView.swift
//  DoloresVoice
//
//  Main UI for Dolores Voice app
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var voiceManager: VoiceManager
    @State private var textInput: String = ""
    @State private var showTextInput: Bool = false
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.black, Color(red: 0.1, green: 0.1, blue: 0.2)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header
                headerView
                
                // Connection status
                connectionStatusView
                
                Spacer()
                
                // Response area
                if !voiceManager.lastResponse.isEmpty {
                    responseView
                }
                
                // Transcript (what user said)
                if !voiceManager.lastTranscript.isEmpty && voiceManager.state == .processing {
                    transcriptView
                }
                
                Spacer()
                
                // Main interaction area
                mainInteractionView
                
                // Error message
                if let error = voiceManager.errorMessage {
                    errorView(error)
                }
                
                Spacer()
                
                // Bottom controls
                bottomControlsView
            }
            .padding()
        }
        .onAppear {
            voiceManager.requestPermissions()
            voiceManager.connect()
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        VStack(spacing: 8) {
            Text("🦋")
                .font(.system(size: 50))
            Text("Dolores")
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundColor(.white)
        }
        .padding(.top, 20)
    }
    
    // MARK: - Connection Status
    
    private var connectionStatusView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(voiceManager.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            
            Text(voiceManager.isConnected ? "Verbonden" : "Niet verbonden")
                .font(.subheadline)
                .foregroundColor(.gray)
            
            if !voiceManager.isConnected {
                Button(action: { voiceManager.reconnect() }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.blue)
                }
            }
        }
    }
    
    // MARK: - Response View
    
    private var responseView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("🦋")
                Text("Dolores")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
            }
            
            Text(voiceManager.lastResponse)
                .font(.body)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.1))
                .cornerRadius(16)
        }
        .padding(.horizontal)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
    
    // MARK: - Transcript View
    
    private var transcriptView: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                Text("Jij")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.gray)
                Text("🎤")
            }
            
            Text(voiceManager.lastTranscript)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .padding()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(Color.blue.opacity(0.2))
                .cornerRadius(16)
        }
        .padding(.horizontal)
    }
    
    // MARK: - Main Interaction
    
    private var mainInteractionView: some View {
        VStack(spacing: 20) {
            // Push-to-talk button
            pushToTalkButton
            
            // Status text
            Text(voiceManager.state.rawValue)
                .font(.headline)
                .foregroundColor(.white)
            
            // Audio level indicator when listening
            if voiceManager.state == .listening {
                audioLevelIndicator
            }
        }
    }
    
    private var pushToTalkButton: some View {
        Button(action: {}) {
            ZStack {
                // Outer ring
                Circle()
                    .stroke(voiceManager.state.color.opacity(0.3), lineWidth: 4)
                    .frame(width: 140, height: 140)
                
                // Pulsing ring when listening
                if voiceManager.state == .listening {
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 2)
                        .frame(width: 160, height: 160)
                        .scaleEffect(1.0 + CGFloat(voiceManager.audioLevel) * 0.3)
                        .animation(.easeInOut(duration: 0.1), value: voiceManager.audioLevel)
                }
                
                // Main button
                Circle()
                    .fill(voiceManager.state.color)
                    .frame(width: 120, height: 120)
                    .shadow(color: voiceManager.state.color.opacity(0.5), radius: 10)
                
                // Icon
                Image(systemName: voiceManager.state.icon)
                    .font(.system(size: 50))
                    .foregroundColor(.white)
                    .symbolEffect(.pulse, isActive: voiceManager.state == .processing || voiceManager.state == .connecting)
            }
        }
        .buttonStyle(PushToTalkButtonStyle(
            isListening: voiceManager.state == .listening,
            onPress: { voiceManager.startRecording() },
            onRelease: { voiceManager.stopRecording() }
        ))
        .disabled(!voiceManager.isConnected || voiceManager.state == .processing || voiceManager.state == .speaking || voiceManager.state == .connecting)
    }
    
    private var audioLevelIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.red.opacity(Double(i) < Double(voiceManager.audioLevel * 10) ? 1 : 0.3))
                    .frame(width: 8, height: 20)
            }
        }
    }
    
    // MARK: - Error View
    
    private func errorView(_ error: String) -> some View {
        Text(error)
            .font(.caption)
            .foregroundColor(.red)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.1))
            .cornerRadius(8)
    }
    
    // MARK: - Bottom Controls
    
    private var bottomControlsView: some View {
        VStack(spacing: 12) {
            // Toggle for text input
            Button(action: { withAnimation { showTextInput.toggle() } }) {
                HStack {
                    Image(systemName: showTextInput ? "keyboard.chevron.compact.down" : "keyboard")
                    Text(showTextInput ? "Verberg toetsenbord" : "Typ een bericht")
                }
                .font(.caption)
                .foregroundColor(.gray)
            }
            
            // Text input field
            if showTextInput {
                HStack {
                    TextField("Typ een bericht...", text: $textInput)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(20)
                        .foregroundColor(.white)
                        .focused($isTextFieldFocused)
                        .onSubmit { sendTextMessage() }
                    
                    Button(action: sendTextMessage) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.blue)
                            .clipShape(Circle())
                    }
                    .disabled(textInput.isEmpty || voiceManager.state == .processing)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 20)
    }
    
    // MARK: - Actions
    
    private func sendTextMessage() {
        guard !textInput.isEmpty else { return }
        voiceManager.sendText(textInput)
        textInput = ""
        isTextFieldFocused = false
        withAnimation { showTextInput = false }
    }
}

// MARK: - Push-to-Talk Button Style

struct PushToTalkButtonStyle: ButtonStyle {
    let isListening: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                if isPressed {
                    onPress()
                } else {
                    onRelease()
                }
            }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(VoiceManager())
}
