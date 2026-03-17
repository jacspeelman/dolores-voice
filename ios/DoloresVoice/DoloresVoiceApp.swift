//
//  DoloresVoiceApp.swift
//  DoloresVoice
//
//  Voice assistant app for communicating with Dolores
//  Supports Classic (Deepgram+ElevenLabs) and Realtime (OpenAI WebRTC) modes
//

import SwiftUI

@main
struct DoloresVoiceApp: App {
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
