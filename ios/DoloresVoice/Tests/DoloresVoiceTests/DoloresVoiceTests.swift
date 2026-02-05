// DoloresVoiceTests.swift
// Basic tests for Dolores Voice app

import XCTest
@testable import DoloresVoice

final class DoloresVoiceTests: XCTestCase {
    
    func testVoiceStateColors() throws {
        // Test that all voice states have associated colors
        XCTAssertNotNil(VoiceState.idle.color)
        XCTAssertNotNil(VoiceState.listening.color)
        XCTAssertNotNil(VoiceState.processing.color)
        XCTAssertNotNil(VoiceState.speaking.color)
        XCTAssertNotNil(VoiceState.error.color)
    }
    
    func testVoiceStateIcons() throws {
        // Test that all voice states have associated icons
        XCTAssertFalse(VoiceState.idle.icon.isEmpty)
        XCTAssertFalse(VoiceState.listening.icon.isEmpty)
        XCTAssertFalse(VoiceState.processing.icon.isEmpty)
        XCTAssertFalse(VoiceState.speaking.icon.isEmpty)
        XCTAssertFalse(VoiceState.error.icon.isEmpty)
    }
}
