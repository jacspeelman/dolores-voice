// DoloresVoiceApp.swift
// Dolores Voice - iOS Voice Assistant
//
// Main entry point for the SwiftUI application.
// Initializes the app and sets up the main view hierarchy.

import SwiftUI

/// Main application entry point
@main
struct DoloresVoiceApp: App {
    // MARK: - State Objects
    
    /// Shared audio manager instance for voice capture
    @StateObject private var audioManager = AudioManager()
    
    /// Shared WebSocket manager for server communication
    @StateObject private var webSocketManager = WebSocketManager()
    
    /// Shared TTS manager for voice output
    @StateObject private var ttsManager = TTSManager()
    
    // MARK: - Body
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioManager)
                .environmentObject(webSocketManager)
                .environmentObject(ttsManager)
                .onAppear {
                    setupApp()
                }
        }
    }
    
    // MARK: - Private Methods
    
    /// Initial app setup
    private func setupApp() {
        // Request microphone permission on launch
        Task {
            await audioManager.requestPermission()
        }
        
        // Connect WebSocket (will be configured later)
        // webSocketManager.connect()
        
        print("🎙️ Dolores Voice App initialized")
    }
}
