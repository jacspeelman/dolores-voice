//
//  ContentView.swift
//  DoloresVoice
//
//  Pure voice interface - no text, no chat
//  Visual feedback via pulsing circle
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var voiceManager: VoiceManager
    
    var body: some View {
        ZStack {
            // Dark background
            Color.black.ignoresSafeArea()
            
            VStack {
                Spacer()
                
                // Pulsing circle in center
                ZStack {
                    // Outer pulse animation
                    if voiceManager.state == .listening {
                        Circle()
                            .stroke(voiceManager.state.color.opacity(0.3), lineWidth: 3)
                            .frame(
                                width: 200 + CGFloat(voiceManager.audioLevel * 80),
                                height: 200 + CGFloat(voiceManager.audioLevel * 80)
                            )
                            .animation(.easeOut(duration: 0.1), value: voiceManager.audioLevel)
                    }
                    
                    // Processing spinner
                    if voiceManager.state == .processing {
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(voiceManager.state.color, lineWidth: 4)
                            .frame(width: 220, height: 220)
                            .rotationEffect(.degrees(voiceManager.spinnerRotation))
                    }
                    
                    // Speaking waveform
                    if voiceManager.state == .speaking {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .stroke(voiceManager.state.color.opacity(0.5), lineWidth: 2)
                                .frame(width: 200 + CGFloat(index * 30), height: 200 + CGFloat(index * 30))
                                .scaleEffect(voiceManager.waveformScale)
                                .opacity(1.0 - Double(index) * 0.3)
                        }
                    }
                    
                    // Main circle
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    voiceManager.state.color.opacity(0.8),
                                    voiceManager.state.color.opacity(0.4)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .shadow(color: voiceManager.state.color.opacity(0.5), radius: 20)
                    
                    // State icon
                    Image(systemName: voiceManager.state.icon)
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                // Bottom status
                VStack(spacing: 12) {
                    // Connection status dot
                    HStack(spacing: 8) {
                        Circle()
                            .fill(voiceManager.isConnected ? Color.green : Color.red)
                            .frame(width: 12, height: 12)
                        
                        Text(voiceManager.isConnected ? "Verbonden" : "Niet verbonden")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    
                    // Error message
                    if let error = voiceManager.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    
                    // Reconnect button
                    if !voiceManager.isConnected {
                        Button("Opnieuw verbinden") {
                            voiceManager.reconnect()
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(8)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            voiceManager.checkPermissions()
            voiceManager.connect()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(VoiceManager())
}
