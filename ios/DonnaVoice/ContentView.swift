//
//  ContentView.swift
//  DonnaVoice
//
//  Pure voice interface - no text, no chat
//  Visual feedback via pulsing circle
//  Supports both Classic (Deepgram+ElevenLabs) and Realtime (OpenAI WebRTC) modes
//

import SwiftUI

/// Classic mode voice view (existing Deepgram + ElevenLabs pipeline)
struct ClassicVoiceView: View {
    @EnvironmentObject var voiceManager: VoiceManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                // Mode indicator at top
                HStack {
                    Spacer()
                    Text("Classic")
                        .font(.caption2)
                        .foregroundColor(.blue.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(8)
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                }

                Spacer()

                // Pulsing circle in center
                ZStack {
                    // Listening: pulsing rings identical to speaking rings
                    if voiceManager.state == .listening && voiceManager.audioLevel > 0.05 {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .stroke(voiceManager.state.color.opacity(0.5), lineWidth: 2)
                                .frame(width: 200 + CGFloat(index * 30), height: 200 + CGFloat(index * 30))
                                .scaleEffect(voiceManager.listeningWaveformScale)
                                .opacity(1.0 - Double(index) * 0.3)
                        }
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
                    // Speaker toggle
                    Button {
                        voiceManager.useLoudspeaker.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: voiceManager.useLoudspeaker ? "speaker.wave.3.fill" : "ear.fill")
                                .font(.body)
                            Text(voiceManager.useLoudspeaker ? "Luidspreker" : "Telefoon")
                                .font(.caption)
                        }
                        .foregroundColor(voiceManager.useLoudspeaker ? .blue : .gray)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(16)
                    }

                    // Connection status dot
                    HStack(spacing: 8) {
                        Circle()
                            .fill(voiceManager.isConnected ? Color.green : Color.red)
                            .frame(width: 12, height: 12)

                        Text(voiceManager.isConnected ? "Verbonden (Classic)" : "Niet verbonden")
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
        .onDisappear {
            voiceManager.disconnect()
        }
    }
}

struct SettingsView: View {
    @AppStorage("serverHost") private var serverHost = "192.168.1.66"
    @AppStorage("serverPort") private var serverPort = "8765"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server")) {
                    HStack {
                        Text("IP adres")
                            .foregroundColor(.gray)
                        TextField("192.168.1.66", text: $serverHost)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    HStack {
                        Text("Poort")
                            .foregroundColor(.gray)
                        TextField("8765", text: $serverPort)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    Text("Herstart de verbinding na het wijzigen van het adres.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Instellingen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Klaar") { dismiss() }
                }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var voiceManager: VoiceManager
    @EnvironmentObject var realtimeManager: RealtimeVoiceManager

    @AppStorage("useRealtimeMode") private var useRealtimeMode = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: mode toggle + settings
                HStack {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(.gray)
                            .font(.body)
                    }

                    Spacer()

                    Text("Classic")
                        .font(.caption)
                        .foregroundColor(useRealtimeMode ? .gray : .blue)

                    Toggle("", isOn: $useRealtimeMode)
                        .toggleStyle(SwitchToggleStyle(tint: .purple))
                        .labelsHidden()
                        .onChange(of: useRealtimeMode) { _, newValue in
                            // Disconnect the old mode when switching
                            if newValue {
                                voiceManager.disconnect()
                            } else {
                                realtimeManager.disconnect()
                            }
                        }

                    Text("Realtime")
                        .font(.caption)
                        .foregroundColor(useRealtimeMode ? .purple : .gray)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)

                // Mode-specific view
                if useRealtimeMode {
                    RealtimeVoiceView()
                        .environmentObject(realtimeManager)
                } else {
                    ClassicVoiceView()
                        .environmentObject(voiceManager)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(VoiceManager())
        .environmentObject(RealtimeVoiceManager())
}
