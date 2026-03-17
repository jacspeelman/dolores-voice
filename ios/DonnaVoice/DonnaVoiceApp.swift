//
//  DonnaVoiceApp.swift
//  DonnaVoice
//
//  Voice assistant app for communicating with Donna
//  Supports Classic (Deepgram+ElevenLabs) and Realtime (OpenAI WebRTC) modes
//

import SwiftUI

@main
struct DonnaVoiceApp: App {
    @StateObject private var voiceManager = VoiceManager()
    @StateObject private var realtimeManager = RealtimeVoiceManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(voiceManager)
                .environmentObject(realtimeManager)
        }
    }
}
