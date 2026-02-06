//
//  ContentView.swift
//  DoloresVoice
//
//  Voice assistant UI with push-to-talk
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var voiceManager: VoiceManager
    @State private var textInput: String = ""
    @State private var showTextInput: Bool = false
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 8) {
                    Text("🦋")
                        .font(.system(size: 60))
                    Text("Dolores")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                .padding(.top, 30)
                
                // Connection status
                connectionStatus
                
                Spacer()
                
                // Response
                if !voiceManager.lastResponse.isEmpty {
                    responseView
                }
                
                // Transcript while listening
                if voiceManager.state == .listening && !voiceManager.lastTranscript.isEmpty {
                    transcriptView
                }
                
                Spacer()
                
                // Main button
                mainButton
                
                // Status text
                Text(voiceManager.state.rawValue)
                    .font(.headline)
                    .foregroundColor(.white)
                
                // Error
                if let error = voiceManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                Spacer()
                
                // Text input toggle
                bottomControls
            }
            .padding()
        }
        .onAppear {
            voiceManager.checkPermissions()
            voiceManager.connect()
        }
        .onTapGesture {
            isTextFieldFocused = false
        }
    }
    
    // MARK: - Connection Status
    
    private var connectionStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(voiceManager.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            
            Text(voiceManager.isConnected ? "Verbonden" : "Niet verbonden")
                .font(.subheadline)
                .foregroundColor(.gray)
            
            if !voiceManager.isConnected && voiceManager.state != .connecting {
                Button("Opnieuw") {
                    voiceManager.reconnect()
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }
        }
    }
    
    // MARK: - Response View
    
    private var responseView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🦋 Dolores:")
                .font(.caption)
                .foregroundColor(.gray)
            
            Text(voiceManager.lastResponse)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.1))
                .cornerRadius(12)
        }
        .padding(.horizontal)
    }
    
    // MARK: - Transcript View
    
    private var transcriptView: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Text("🎤 Jij:")
                .font(.caption)
                .foregroundColor(.gray)
            
            Text(voiceManager.lastTranscript)
                .foregroundColor(.white.opacity(0.8))
                .padding()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(Color.blue.opacity(0.2))
                .cornerRadius(12)
        }
        .padding(.horizontal)
    }
    
    // MARK: - Main Button
    
    private var mainButton: some View {
        Button(action: {}) {
            ZStack {
                // Outer glow when listening
                if voiceManager.state == .listening {
                    Circle()
                        .fill(Color.red.opacity(0.2))
                        .frame(width: 160, height: 160)
                }
                
                // Main circle
                Circle()
                    .fill(voiceManager.state.color)
                    .frame(width: 120, height: 120)
                    .shadow(color: voiceManager.state.color.opacity(0.5), radius: 10)
                
                // Icon
                Image(systemName: voiceManager.state.icon)
                    .font(.system(size: 50))
                    .foregroundColor(.white)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if voiceManager.state == .idle && voiceManager.isConnected && voiceManager.canUseSpeech {
                        voiceManager.startListening()
                    }
                }
                .onEnded { _ in
                    if voiceManager.state == .listening {
                        voiceManager.stopListening()
                    }
                }
        )
        .disabled(!voiceManager.isConnected || voiceManager.state == .processing || voiceManager.state == .speaking)
        .opacity(buttonOpacity)
    }
    
    private var buttonOpacity: Double {
        if !voiceManager.isConnected { return 0.5 }
        if voiceManager.state == .processing || voiceManager.state == .speaking { return 0.7 }
        return 1.0
    }
    
    // MARK: - Bottom Controls
    
    private var bottomControls: some View {
        VStack(spacing: 12) {
            // Toggle text input
            Button(action: { withAnimation { showTextInput.toggle() } }) {
                HStack {
                    Image(systemName: showTextInput ? "keyboard.chevron.compact.down" : "keyboard")
                    Text(showTextInput ? "Verberg" : "Typ een bericht")
                }
                .font(.caption)
                .foregroundColor(.gray)
            }
            
            // Text input
            if showTextInput {
                HStack {
                    TextField("Typ een bericht...", text: $textInput)
                        .padding(14)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(25)
                        .foregroundColor(.white)
                        .focused($isTextFieldFocused)
                        .onSubmit { sendText() }
                    
                    Button(action: sendText) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(canSend ? .blue : .gray)
                    }
                    .disabled(!canSend)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            if !voiceManager.canUseSpeech {
                Text("Geef toegang tot microfoon in Instellingen")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(.bottom, 20)
    }
    
    private var canSend: Bool {
        !textInput.isEmpty && voiceManager.isConnected && voiceManager.state == .idle
    }
    
    private func sendText() {
        guard canSend else { return }
        voiceManager.sendText(textInput)
        textInput = ""
        isTextFieldFocused = false
        withAnimation { showTextInput = false }
    }
}

#Preview {
    ContentView()
        .environmentObject(VoiceManager())
}
