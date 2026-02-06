//
//  ContentView.swift
//  DoloresVoice
//
//  Simple text input UI - send messages, hear responses
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
            
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("🦋")
                        .font(.system(size: 60))
                    Text("Dolores")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                .padding(.top, 40)
                
                // Connection status
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
                
                Spacer()
                
                // Response
                if !voiceManager.lastResponse.isEmpty {
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
                
                Spacer()
                
                // Status
                VStack(spacing: 12) {
                    Image(systemName: voiceManager.state.icon)
                        .font(.system(size: 50))
                        .foregroundColor(voiceManager.state.color)
                    
                    Text(voiceManager.state.rawValue)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
                if let error = voiceManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                Spacer()
                
                // Text input
                HStack {
                    TextField("Typ een bericht...", text: $textInput)
                        .padding(14)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(25)
                        .foregroundColor(.white)
                        .focused($isTextFieldFocused)
                        .onSubmit { send() }
                    
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(canSend ? .blue : .gray)
                    }
                    .disabled(!canSend)
                }
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            voiceManager.connect()
        }
        .onTapGesture {
            isTextFieldFocused = false
        }
    }
    
    private var canSend: Bool {
        !textInput.isEmpty && voiceManager.isConnected && voiceManager.state == .idle
    }
    
    private func send() {
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
