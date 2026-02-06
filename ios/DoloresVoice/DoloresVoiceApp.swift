//
//  DoloresVoiceApp.swift
//  DoloresVoice
//
//  Voice assistant app for communicating with Dolores
//

import SwiftUI

@main
struct DoloresVoiceApp: App {
    @StateObject private var voiceManager = VoiceManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(voiceManager)
        }
    }
}
