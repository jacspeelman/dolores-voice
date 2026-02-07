//
//  ContentView.swift
//  DoloresVoice
//
//  Telegram-style chat UI
//  v2: Streaming text support
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var voiceManager: VoiceManager
    @State private var textInput: String = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Compact Header
                compactHeader
                
                // Chat messages (scrollable)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(voiceManager.messages) { message in
                                chatBubble(message: message)
                            }
                            
                            // Current transcript (typing indicator)
                            if voiceManager.state == .listening && !voiceManager.lastTranscript.isEmpty {
                                currentTranscript
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: voiceManager.messages.count) { _ in
                        if let lastMessage = voiceManager.messages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: voiceManager.streamingResponse) { _ in
                        // Auto-scroll while streaming text
                        if let lastMessage = voiceManager.messages.last {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                
                // Bottom bar with button and input
                bottomBar
            }
        }
        .onAppear {
            voiceManager.checkPermissions()
            voiceManager.connect()
        }
        .onTapGesture {
            isTextFieldFocused = false
        }
    }
    
    // MARK: - Compact Header
    
    private var compactHeader: some View {
        HStack(spacing: 10) {
            Text("🦋")
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Dolores")
                    .font(.headline)
                    .foregroundColor(.white)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(voiceManager.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    
                    Text(voiceManager.isConnected ? "Verbonden" : "Niet verbonden")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
            
            if !voiceManager.isConnected && voiceManager.state != .connecting {
                Button("Opnieuw") {
                    voiceManager.reconnect()
                }
                .font(.caption)
                .foregroundColor(.blue)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.9))
    }
    
    // MARK: - Chat Bubble
    
    private func chatBubble(message: ChatMessage) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 60) }
            
            Text(message.text)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.isUser ? Color.blue : Color.gray.opacity(0.3))
                .cornerRadius(18)
            
            if !message.isUser { Spacer(minLength: 60) }
        }
        .id(message.id)
    }
    
    // MARK: - Current Transcript
    
    private var currentTranscript: some View {
        HStack {
            Spacer(minLength: 60)
            Text(voiceManager.lastTranscript)
                .foregroundColor(.white.opacity(0.7))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.5))
                .cornerRadius(18)
        }
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        VStack(spacing: 8) {
            // Error message
            if let error = voiceManager.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
            
            // Status text
            if voiceManager.state != .idle && voiceManager.state != .disconnected {
                Text(voiceManager.state.rawValue)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            HStack(spacing: 10) {
                // Text input field (always visible)
                TextField("Bericht...", text: $textInput)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(22)
                    .foregroundColor(.white)
                    .focused($isTextFieldFocused)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .onSubmit { sendText() }
                
                // Send button
                Button(action: sendText) {
                    Circle()
                        .fill(canSend ? Color.blue : Color.gray.opacity(0.3))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "arrow.up")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                        )
                }
                .disabled(!canSend)
                
                // Voice button
                voiceButton
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.9))
        }
    }
    
    // MARK: - Voice Button
    
    private var voiceButton: some View {
        Button(action: {
            if voiceManager.isConnected && voiceManager.canUseSpeech {
                voiceManager.toggleConversation()
            }
        }) {
            ZStack {
                // Pulse animation when listening
                if voiceManager.state == .listening {
                    Circle()
                        .stroke(Color.green.opacity(0.3), lineWidth: 2)
                        .frame(width: 44 + CGFloat(voiceManager.audioLevel * 15),
                               height: 44 + CGFloat(voiceManager.audioLevel * 15))
                        .animation(.easeOut(duration: 0.1), value: voiceManager.audioLevel)
                }
                
                Circle()
                    .fill(voiceManager.state.color)
                    .frame(width: 44, height: 44)
                
                Image(systemName: voiceManager.state.icon)
                    .font(.system(size: 20))
                    .foregroundColor(.white)
            }
        }
        .disabled(!voiceManager.isConnected || !voiceManager.canUseSpeech)
        .opacity(voiceManager.isConnected && voiceManager.canUseSpeech ? 1.0 : 0.5)
    }
    
    private var canSend: Bool {
        !textInput.isEmpty && voiceManager.isConnected && 
        (voiceManager.state == .idle || voiceManager.state == .listening)
    }
    
    private func sendText() {
        guard canSend else { return }
        voiceManager.sendText(textInput)
        textInput = ""
        isTextFieldFocused = false
    }
}

#Preview {
    ContentView()
        .environmentObject(VoiceManager())
}
