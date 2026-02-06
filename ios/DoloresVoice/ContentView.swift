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
            
            VStack(spacing: 30) {
                // Header
                VStack(spacing: 8) {
                    Text("🦋")
                        .font(.system(size: 50))
                    Text("Dolores")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                }
                .padding(.top, 40)
                
                // Connection status
                HStack {
                    Circle()
                        .fill(voiceManager.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(voiceManager.isConnected ? "Verbonden" : "Niet verbonden")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // Response area
                if !voiceManager.lastResponse.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dolores:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(voiceManager.lastResponse)
                            .font(.body)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(12)
                    }
                    .padding(.horizontal)
                }
                
                Spacer()
                
                // Status indicator
                VStack(spacing: 12) {
                    Image(systemName: voiceManager.state.icon)
                        .font(.system(size: 60))
                        .foregroundColor(voiceManager.state.color)
                        .symbolEffect(.pulse, isActive: voiceManager.state == .processing)
                    
                    Text(voiceManager.state.rawValue)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
                // Error message
                if let error = voiceManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }
                
                Spacer()
                
                // Text input (temporary until voice is fully working)
                VStack(spacing: 12) {
                    HStack {
                        TextField("Typ een bericht...", text: $textInput)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(20)
                            .foregroundColor(.white)
                            .focused($isTextFieldFocused)
                            .onSubmit {
                                sendMessage()
                            }
                        
                        Button(action: sendMessage) {
                            Image(systemName: "paperplane.fill")
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Color.blue)
                                .clipShape(Circle())
                        }
                        .disabled(textInput.isEmpty || voiceManager.state == .processing)
                    }
                    .padding(.horizontal)
                    
                    Text("Spraakherkenning komt binnenkort!")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            voiceManager.connect()
        }
    }
    
    private func sendMessage() {
        guard !textInput.isEmpty else { return }
        voiceManager.sendText(textInput)
        textInput = ""
        isTextFieldFocused = false
    }
}

#Preview {
    ContentView()
        .environmentObject(VoiceManager())
}
