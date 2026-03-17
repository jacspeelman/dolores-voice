//
//  RealtimeVoiceView.swift
//  DoloresVoice
//
//  UI for OpenAI Realtime mode — same visual style as Classic mode
//  with pulsing circles, but backed by RealtimeVoiceManager.
//

import SwiftUI

struct RealtimeVoiceView: View {
    @EnvironmentObject var realtimeManager: RealtimeVoiceManager

    var body: some View {
        ZStack {
            // Dark background
            Color.black.ignoresSafeArea()

            VStack {
                // Mode indicator at top
                HStack {
                    Spacer()
                    Text("Realtime")
                        .font(.caption2)
                        .foregroundColor(.purple.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.15))
                        .cornerRadius(8)
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                }

                Spacer()

                // Pulsing circle in center — same design as Classic
                ZStack {
                    // Listening: pulsing rings when user is speaking
                    if realtimeManager.state == .listening && realtimeManager.audioLevel > 0.05 {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .stroke(realtimeManager.state.color.opacity(0.5), lineWidth: 2)
                                .frame(width: 200 + CGFloat(index * 30), height: 200 + CGFloat(index * 30))
                                .scaleEffect(realtimeManager.listeningWaveformScale)
                                .opacity(1.0 - Double(index) * 0.3)
                        }
                    }

                    // Processing spinner
                    if realtimeManager.state == .processing {
                        Circle()
                            .trim(from: 0, to: 0.7)
                            .stroke(realtimeManager.state.color, lineWidth: 4)
                            .frame(width: 220, height: 220)
                            .rotationEffect(.degrees(realtimeManager.spinnerRotation))
                    }

                    // Speaking waveform
                    if realtimeManager.state == .speaking {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .stroke(realtimeManager.state.color.opacity(0.5), lineWidth: 2)
                                .frame(width: 200 + CGFloat(index * 30), height: 200 + CGFloat(index * 30))
                                .scaleEffect(realtimeManager.waveformScale)
                                .opacity(1.0 - Double(index) * 0.3)
                        }
                    }

                    // Main circle
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    realtimeManager.state.color.opacity(0.8),
                                    realtimeManager.state.color.opacity(0.4)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .shadow(color: realtimeManager.state.color.opacity(0.5), radius: 20)

                    // State icon
                    Image(systemName: realtimeManager.state.icon)
                        .font(.system(size: 60))
                        .foregroundColor(.white)
                }

                Spacer()

                // Transcript (last few messages)
                if !realtimeManager.transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(realtimeManager.transcript.suffix(4)) { msg in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: msg.role == .user ? "person.fill" : "brain")
                                    .font(.caption2)
                                    .foregroundColor(msg.role == .user ? .blue : .green)
                                    .frame(width: 14)

                                Text(msg.text)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }

                // Bottom status
                VStack(spacing: 12) {
                    // Connection status dot
                    HStack(spacing: 8) {
                        Circle()
                            .fill(realtimeManager.isConnected ? Color.green : Color.red)
                            .frame(width: 12, height: 12)

                        Text(realtimeManager.isConnected ? "Verbonden (Realtime)" : "Niet verbonden")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }

                    // Error message
                    if let error = realtimeManager.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Reconnect button
                    if !realtimeManager.isConnected && !realtimeManager.isConnecting {
                        Button("Opnieuw verbinden") {
                            realtimeManager.reconnect()
                        }
                        .font(.caption)
                        .foregroundColor(.purple)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.purple.opacity(0.2))
                        .cornerRadius(8)
                    }

                    if realtimeManager.isConnecting {
                        ProgressView()
                            .tint(.purple)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            realtimeManager.checkPermissions()
            realtimeManager.connect()
        }
        .onDisappear {
            realtimeManager.disconnect()
        }
    }
}

#Preview {
    RealtimeVoiceView()
        .environmentObject(RealtimeVoiceManager())
}
