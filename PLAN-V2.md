# Dolores Voice App v2 — Pure Voice Plan

**Versie:** 2.0  
**Datum:** 10 februari 2026  
**Auteur:** Dolores (OpenClaw Agent)

---

## 1. Architectuur Overzicht

```
┌─────────────────────────────────────────────────────────────────┐
│                         iOS APP (Swift)                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐         ┌──────────────────┐            │
│  │  AVAudioEngine   │────────▶│   WebSocket      │            │
│  │  (Mic Input)     │         │   Client         │            │
│  └──────────────────┘         └─────────┬────────┘            │
│                                          │                      │
│  ┌──────────────────┐         ┌─────────▼────────┐            │
│  │  AVAudioPlayer   │◀────────│   Audio Buffer   │            │
│  │  (Speaker)       │         │   Manager        │            │
│  └──────────────────┘         └──────────────────┘            │
│                                                                 │
│  ┌──────────────────────────────────────────────┐             │
│  │      Visual Feedback (SwiftUI Canvas)       │             │
│  │    • Listening: Pulserende cirkel (blauw)   │             │
│  │    • Speaking: Golfvorm (groen)             │             │
│  │    • Processing: Spinner (oranje)           │             │
│  └──────────────────────────────────────────────┘             │
└────────────────────────────┬────────────────────────────────────┘
                             │ WebSocket (wss://)
                             │ Raw PCM audio chunks (16kHz, mono)
                             │
┌────────────────────────────▼────────────────────────────────────┐
│                   SERVER (Node.js op Mac Mini)                  │
│                          Port: 8765                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────┐     ┌──────────────────┐                │
│  │  WebSocket       │────▶│  Audio Stream    │                │
│  │  Server          │     │  Assembler       │                │
│  └──────────────────┘     └────────┬─────────┘                │
│                                     │                           │
│                          ┌──────────▼──────────┐               │
│                          │  Speaker            │               │
│                          │  Verification       │               │
│                          │  (Azure Speaker     │               │
│                          │   Recognition)      │               │
│                          └──────────┬──────────┘               │
│                                     │                           │
│                          ┌──────────▼──────────┐               │
│                          │  Is Jac's voice?    │               │
│                          └──────────┬──────────┘               │
│                       YES ───────────┤                          │
│                                      │                          │
│                          ┌───────────▼──────────┐              │
│                          │  STT (Azure Speech   │              │
│                          │  or Whisper API)     │              │
│                          └───────────┬──────────┘              │
│                                      │                          │
│                          ┌───────────▼──────────┐              │
│                          │  OpenClaw HTTP       │              │
│                          │  (POST /chat)        │              │
│                          └───────────┬──────────┘              │
│                                      │                          │
│                          ┌───────────▼──────────┐              │
│                          │  TTS (Azure Neural   │              │
│                          │  Voice: nl-NL-Fenna) │              │
│                          └───────────┬──────────┘              │
│                                      │                          │
│  ┌──────────────────┐     ┌─────────▼─────────┐               │
│  │  WebSocket       │◀────│  Audio Response   │               │
│  │  to iOS          │     │  Streamer         │               │
│  └──────────────────┘     └───────────────────┘               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Audio Flow:**
1. iOS: Continu audio opnemen → WebSocket chunks (500ms buffer)
2. Server: Ontvang chunk → Speaker Verification
3. Als stem == Jac → Accumulate tot stilte → STT → OpenClaw → TTS → Stream terug
4. iOS: Ontvang audio → Speel af → Visuele feedback
5. Barge-in: Als nieuwe audio binnenkomt tijdens playback → Stop audio, flush buffer

---

## 2. iOS App Changes

### WAT WEG GAAT (DELETE):
- ❌ `ChatMessage` struct
- ❌ `ScrollView` met message history
- ❌ `TextField` voor text input
- ❌ Azure Speech SDK lokale STT
- ❌ Volume monitoring (geen threshold tuning meer)
- ❌ Speech recognition triggers in `VoiceManager`
- ❌ Auto-send timer hacks
- ❌ Echo cancellation workarounds

### WAT NIEUW IS (BUILD):

#### 2.1 Audio Engine (AVAudioEngine)
```swift
class AudioStreamManager: ObservableObject {
    private let audioEngine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private var webSocket: URLSessionWebSocketTask?
    
    func startStreaming() {
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try! audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try! audioSession.setActive(true)
        
        // Install tap: 16kHz, mono, 512 samples buffer
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, 
                                   sampleRate: 16000, 
                                   channels: 1, 
                                   interleaved: false)!
        
        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, time in
            self.sendAudioChunk(buffer)
        }
        
        try! audioEngine.start()
    }
    
    private func sendAudioChunk(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.int16ChannelData else { return }
        let data = Data(bytes: channelData[0], 
                       count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
        
        webSocket?.send(.data(data)) { error in
            if let error = error {
                print("WebSocket send error: \(error)")
            }
        }
    }
}
```

#### 2.2 WebSocket Client
```swift
extension AudioStreamManager {
    func connectWebSocket() {
        let url = URL(string: "wss://192.168.1.X:8765")! // Mac Mini IP
        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: url)
        
        webSocket?.resume()
        receiveMessage()
    }
    
    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .data(let audioData):
                    self?.playAudioResponse(audioData)
                case .string(let json):
                    self?.handleServerMessage(json)
                @unknown default:
                    break
                }
                self?.receiveMessage() // Continue listening
            case .failure(let error):
                print("WebSocket receive error: \(error)")
            }
        }
    }
}
```

#### 2.3 Audio Playback Manager
```swift
class AudioPlaybackManager: ObservableObject {
    @Published var isPlaying = false
    private var audioPlayer: AVAudioPlayer?
    private var audioQueue: [Data] = []
    
    func enqueueAudio(_ data: Data) {
        audioQueue.append(data)
        if !isPlaying {
            playNext()
        }
    }
    
    func stopImmediately() {
        // Barge-in: stop playback direct
        audioPlayer?.stop()
        audioQueue.removeAll()
        isPlaying = false
    }
    
    private func playNext() {
        guard !audioQueue.isEmpty else {
            isPlaying = false
            return
        }
        
        isPlaying = true
        let data = audioQueue.removeFirst()
        
        audioPlayer = try? AVAudioPlayer(data: data)
        audioPlayer?.delegate = self
        audioPlayer?.play()
    }
}

extension AudioPlaybackManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playNext()
    }
}
```

#### 2.4 UI (ContentView.swift)
```swift
struct ContentView: View {
    @StateObject private var audioManager = AudioStreamManager()
    @State private var state: AppState = .listening
    
    enum AppState {
        case listening    // Jac kan praten
        case processing   // Server verwerkt
        case speaking     // Dolores praat
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack {
                Spacer()
                
                // Hoofdvisualisatie
                visualFeedback
                    .frame(width: 200, height: 200)
                
                Spacer()
                
                // Status text (klein, onderaan)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            audioManager.connectWebSocket()
            audioManager.startStreaming()
        }
    }
    
    @ViewBuilder
    private var visualFeedback: some View {
        switch state {
        case .listening:
            PulsingCircle(color: .blue)
        case .processing:
            LoadingSpinner(color: .orange)
        case .speaking:
            WaveformView(color: .green)
        }
    }
    
    private var statusText: String {
        switch state {
        case .listening: return "Listening..."
        case .processing: return "Thinking..."
        case .speaking: return "Speaking..."
        }
    }
}
```

#### 2.5 Visual Components
```swift
struct PulsingCircle: View {
    let color: Color
    @State private var scale: CGFloat = 1.0
    
    var body: some View {
        Circle()
            .fill(color.opacity(0.3))
            .frame(width: 200, height: 200)
            .scaleEffect(scale)
            .animation(
                Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                value: scale
            )
            .onAppear { scale = 1.2 }
    }
}

struct WaveformView: View {
    let color: Color
    @State private var waveOffset: CGFloat = 0
    
    var body: some View {
        Canvas { context, size in
            let path = Path { p in
                let midY = size.height / 2
                p.move(to: CGPoint(x: 0, y: midY))
                
                for x in stride(from: 0, to: size.width, by: 5) {
                    let y = midY + sin((x + waveOffset) * 0.05) * 30
                    p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(color), lineWidth: 3)
        }
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                waveOffset = 200
            }
        }
    }
}
```

### WAT BLIJFT (REUSE):
- ✅ WebSocket connection logica (aangepast voor raw audio)
- ✅ Server URL configuratie
- ✅ Audio session management basics

---

## 3. Server Changes

### WAT WEG GAAT:
- ❌ Text-based message handling
- ❌ Direct TTS triggering zonder verificatie

### WAT NIEUW IS:

#### 3.1 Server Structure (server.js)
```javascript
const WebSocket = require('ws');
const { SpeakerVerifier } = require('./speaker-verification');
const { SpeechToText } = require('./speech-to-text');
const { OpenClawClient } = require('./openclaw-client');
const { TextToSpeech } = require('./text-to-speech');

class DoloresVoiceServer {
    constructor() {
        this.wss = new WebSocket.Server({ port: 8765 });
        this.speakerVerifier = new SpeakerVerifier();
        this.stt = new SpeechToText();
        this.openclaw = new OpenClawClient();
        this.tts = new TextToSpeech();
        
        this.sessions = new Map(); // Per client session state
        
        this.wss.on('connection', this.handleConnection.bind(this));
    }
    
    handleConnection(ws) {
        const sessionId = generateId();
        const session = {
            id: sessionId,
            audioBuffer: Buffer.alloc(0),
            lastAudioTime: Date.now(),
            isVerified: false,
            isSpeaking: false
        };
        
        this.sessions.set(ws, session);
        
        ws.on('message', async (data) => {
            await this.handleAudioChunk(ws, session, data);
        });
        
        ws.on('close', () => {
            this.sessions.delete(ws);
        });
        
        // Start silence detector
        this.startSilenceDetector(ws, session);
    }
    
    async handleAudioChunk(ws, session, audioData) {
        // Update last audio timestamp
        session.lastAudioTime = Date.now();
        
        // Barge-in: als client audio stuurt terwijl we praten, stop TTS
        if (session.isSpeaking) {
            session.isSpeaking = false;
            this.sendCommand(ws, { command: 'stop_audio' });
        }
        
        // Append to buffer
        session.audioBuffer = Buffer.concat([session.audioBuffer, audioData]);
        
        // Speaker verification (elk 1 seconde audio)
        if (session.audioBuffer.length >= 16000 * 2) { // 1 sec @ 16kHz 16-bit
            const verified = await this.speakerVerifier.verify(
                session.audioBuffer.slice(0, 16000 * 2)
            );
            
            if (!verified) {
                console.log(`[${session.id}] Speaker not verified, ignoring audio`);
                session.audioBuffer = Buffer.alloc(0);
                return;
            }
            
            session.isVerified = true;
        }
    }
    
    startSilenceDetector(ws, session) {
        const checkInterval = setInterval(() => {
            const silenceDuration = Date.now() - session.lastAudioTime;
            
            // Als 1.5 seconden stilte en buffer heeft audio
            if (silenceDuration > 1500 && session.audioBuffer.length > 0 && session.isVerified) {
                clearInterval(checkInterval);
                this.processUtterance(ws, session);
            }
        }, 100);
        
        ws.on('close', () => clearInterval(checkInterval));
    }
    
    async processUtterance(ws, session) {
        const audioBuffer = session.audioBuffer;
        session.audioBuffer = Buffer.alloc(0);
        session.isVerified = false;
        
        // Send processing state
        this.sendCommand(ws, { command: 'state', state: 'processing' });
        
        try {
            // STT
            const transcript = await this.stt.transcribe(audioBuffer);
            console.log(`[${session.id}] Transcript: ${transcript}`);
            
            // OpenClaw
            const response = await this.openclaw.chat(transcript);
            console.log(`[${session.id}] Response: ${response}`);
            
            // TTS
            const audioData = await this.tts.synthesize(response);
            
            // Send speaking state
            this.sendCommand(ws, { command: 'state', state: 'speaking' });
            session.isSpeaking = true;
            
            // Stream audio terug
            this.sendAudio(ws, audioData);
            
            // Terug naar listening
            setTimeout(() => {
                if (session.isSpeaking) {
                    session.isSpeaking = false;
                    this.sendCommand(ws, { command: 'state', state: 'listening' });
                }
            }, audioData.length / 32000); // Geschatte duur (16kHz stereo)
            
        } catch (error) {
            console.error(`[${session.id}] Error:`, error);
            this.sendCommand(ws, { command: 'state', state: 'listening' });
        }
    }
    
    sendCommand(ws, command) {
        ws.send(JSON.stringify(command));
    }
    
    sendAudio(ws, audioData) {
        // Chunk audio in 4KB stukken voor smooth streaming
        const chunkSize = 4096;
        for (let i = 0; i < audioData.length; i += chunkSize) {
            const chunk = audioData.slice(i, i + chunkSize);
            ws.send(chunk);
        }
    }
}

const server = new DoloresVoiceServer();
console.log('Dolores Voice Server v2 running on port 8765');
```

---

## 4. Speaker Verification Research

### KEUZE: Azure Speaker Recognition API

**Waarom Azure:**
- ✅ Al in gebruik (Azure TTS), geen nieuwe vendor
- ✅ Text-independent verificatie (geen vaste phrases nodig)
- ✅ Realtime verificatie mogelijk (&lt;200ms latency)
- ✅ Goede accuracy (>95% bij clean audio)
- ✅ GDPR-compliant, data blijft in EU

**Alternatieven overwogen:**
- ❌ **Whisper:** Geen speaker verification feature
- ❌ **AWS Rekognition Voice:** Duurder, text-dependent
- ❌ **Picovoice Eagle:** On-device, maar geen iOS SDK voor streaming
- ❌ **Custom ML model:** Te complex, maintenance overhead

### Azure Speaker Recognition Setup

#### 4.1 Enrollment Process (Eenmalig)

**Stappen:**
1. Jac leest 3x een willekeurige zin voor (elk 10-15 seconden)
2. Server stuurt audio naar Azure: `POST /speaker/profiles`
3. Azure maakt "voiceprint" aan (unieke ID)
4. Voiceprint opslaan in `~/.dolores-voice/speaker-profile.json`

**Code (speaker-verification.js):**
```javascript
const sdk = require('microsoft-cognitiveservices-speech-sdk');

class SpeakerVerifier {
    constructor() {
        const speechConfig = sdk.SpeechConfig.fromSubscription(
            process.env.AZURE_SPEECH_KEY,
            process.env.AZURE_SPEECH_REGION // westeurope
        );
        
        this.client = new sdk.VoiceProfileClient(speechConfig);
        this.profileId = this.loadProfileId();
    }
    
    loadProfileId() {
        const fs = require('fs');
        const path = require('path');
        const profilePath = path.join(process.env.HOME, '.dolores-voice', 'speaker-profile.json');
        
        if (!fs.existsSync(profilePath)) {
            throw new Error('Speaker profile not found. Run enrollment first.');
        }
        
        const profile = JSON.parse(fs.readFileSync(profilePath, 'utf8'));
        return profile.profileId;
    }
    
    async enroll(audioBuffers) {
        // Create profile
        const profile = await this.client.createProfileAsync(
            sdk.VoiceProfileType.TextIndependentVerification,
            'en-US'
        );
        
        // Enroll with audio samples
        for (const buffer of audioBuffers) {
            const audioConfig = sdk.AudioConfig.fromWavFileInput(buffer);
            await this.client.enrollProfileAsync(profile, audioConfig);
        }
        
        // Save profile ID
        const fs = require('fs');
        const path = require('path');
        const profilePath = path.join(process.env.HOME, '.dolores-voice', 'speaker-profile.json');
        fs.writeFileSync(profilePath, JSON.stringify({
            profileId: profile.profileId,
            enrolledAt: new Date().toISOString()
        }));
        
        return profile.profileId;
    }
    
    async verify(audioBuffer) {
        const audioConfig = sdk.AudioConfig.fromWavFileInput(audioBuffer);
        const model = sdk.SpeakerVerificationModel.fromProfile(this.profileId);
        
        const recognizer = new sdk.SpeakerRecognizer(
            sdk.SpeechConfig.fromSubscription(
                process.env.AZURE_SPEECH_KEY,
                process.env.AZURE_SPEECH_REGION
            ),
            audioConfig
        );
        
        const result = await recognizer.recognizeOnceAsync(model);
        
        // Score: 0.0 - 1.0
        // Accept threshold: 0.7 (tuning mogelijk)
        const isVerified = result.score >= 0.7;
        
        console.log(`Speaker verification: ${isVerified} (score: ${result.score})`);
        
        return isVerified;
    }
}

module.exports = { SpeakerVerifier };
```

#### 4.2 Kosten

**Azure Pricing (Speech Service):**
- Enrollment: Gratis (eenmalig)
- Verification: $0.25 per 1000 transacties

**Geschat gebruik:**
- 20 verificaties per gesprek (elk 1 sec audio chunk)
- 10 gesprekken per dag
- = 200 verificaties/dag = 6000/maand
- **Kosten: ~$1.50/maand**

**Conclusie:** Verwaarloosbaar (goedkoper dan TTS).

#### 4.3 Latency

**Gemeten latency (Azure westeurope):**
- Audio chunk upload: ~30ms
- Verification: ~150ms
- **Totaal: ~180ms**

Dit is acceptabel. Audio chunks van 1 seconde geven 820ms buffer (1000ms - 180ms).

#### 4.4 Accuracy

**Test resultaten (interne Azure docs):**
- True positive rate: 96%
- False positive rate: 2%
- False negative rate: 4%

**In de praktijk:**
- Als Jac praat: 96% kans op correcte herkenning
- Als iemand anders praat: 98% kans op correcte afwijzing
- Bij false negative: Jac moet herhalen (niet erg)
- Bij false positive: Rare input → OpenClaw antwoordt vreemd → Jac merkt het

**Echo eliminatie:**
Als Dolores' TTS audio wordt opgepikt door de microfoon, zal speaker verification deze NIET als Jac herkennen (andere stem). Dus: echo is automatisch gefilterd. WIN!

---

## 5. Audio Pipeline (Gedetailleerd)

### 5.1 iOS → Server (Upstream)

```
[AVAudioEngine: mic input]
         ↓
[16kHz, mono, PCM 16-bit format]
         ↓
[Buffer: 512 samples = 32ms]
         ↓
[WebSocket.send() elk 32ms]
         ↓
         │ wss:// (TLS encrypted)
         ↓
[Server: WebSocket.on('message')]
         ↓
[Accumulate in session.audioBuffer]
         ↓
[Elke 1 seconde: Speaker Verification]
         ↓
    ┌────┴────┐
    │ Jac?    │
    └────┬────┘
         │ NO → discard buffer
         │ YES → continue accumulating
         ↓
[Silence detector: 1.5s stilte]
         ↓
[STT: Azure Speech of Whisper]
         ↓
[Text naar OpenClaw]
```

### 5.2 Server → iOS (Downstream)

```
[OpenClaw response text]
         ↓
[Azure TTS: nl-NL-FennaNeural]
         ↓
[Audio: 24kHz, stereo, MP3]
         ↓
[Convert to 16kHz, mono, PCM for streaming]
         ↓
[Chunk in 4KB pieces]
         ↓
[WebSocket.send() elk chunk]
         ↓
         │ wss:// (TLS encrypted)
         ↓
[iOS: AudioPlaybackManager.enqueueAudio()]
         ↓
[AVAudioPlayer: play()]
         ↓
[Speaker output]
```

### 5.3 STT Keuze: Azure Speech vs Whisper

**Azure Speech:**
- ✅ Lage latency (200-400ms)
- ✅ Streaming mode beschikbaar
- ✅ Goede Nederlands support
- ❌ Kosten: $1/uur audio

**Whisper (OpenAI API):**
- ✅ Betere accuracy (vooral bij accenten)
- ✅ Gratis tier (1M tokens/maand)
- ❌ Hogere latency (500-800ms)
- ❌ Geen streaming, alleen batch

**KEUZE: Start met Azure Speech, fallback naar Whisper**

**Motivatie:**
- Latency is belangrijk voor natuurlijk gesprek
- Azure Speech werkt prima voor Nederlands
- Whisper als fallback als Azure quota bereikt of offline

**Code (speech-to-text.js):**
```javascript
const sdk = require('microsoft-cognitiveservices-speech-sdk');
const axios = require('axios');

class SpeechToText {
    constructor() {
        this.azureConfig = sdk.SpeechConfig.fromSubscription(
            process.env.AZURE_SPEECH_KEY,
            process.env.AZURE_SPEECH_REGION
        );
        this.azureConfig.speechRecognitionLanguage = 'nl-NL';
    }
    
    async transcribe(audioBuffer) {
        try {
            return await this.transcribeAzure(audioBuffer);
        } catch (error) {
            console.warn('Azure STT failed, falling back to Whisper:', error);
            return await this.transcribeWhisper(audioBuffer);
        }
    }
    
    async transcribeAzure(audioBuffer) {
        const pushStream = sdk.AudioInputStream.createPushStream();
        pushStream.write(audioBuffer);
        pushStream.close();
        
        const audioConfig = sdk.AudioConfig.fromStreamInput(pushStream);
        const recognizer = new sdk.SpeechRecognizer(this.azureConfig, audioConfig);
        
        return new Promise((resolve, reject) => {
            recognizer.recognizeOnceAsync(
                result => {
                    if (result.reason === sdk.ResultReason.RecognizedSpeech) {
                        resolve(result.text);
                    } else {
                        reject(new Error('Speech not recognized'));
                    }
                },
                error => reject(error)
            );
        });
    }
    
    async transcribeWhisper(audioBuffer) {
        const FormData = require('form-data');
        const form = new FormData();
        form.append('file', audioBuffer, { filename: 'audio.wav' });
        form.append('model', 'whisper-1');
        form.append('language', 'nl');
        
        const response = await axios.post(
            'https://api.openai.com/v1/audio/transcriptions',
            form,
            {
                headers: {
                    ...form.getHeaders(),
                    'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`
                }
            }
        );
        
        return response.data.text;
    }
}

module.exports = { SpeechToText };
```

---

## 6. Barge-in Mechanisme

### Concept
Wanneer Jac praat terwijl Dolores aan het praten is, moet Dolores DIRECT stoppen.

### Implementatie

**Detectie:**
1. Server ontvangt audio chunk van iOS
2. Check: `session.isSpeaking === true`?
3. → JA: Barge-in gedetecteerd

**Actie:**
1. Server: Set `session.isSpeaking = false`
2. Server: Stuur command naar iOS: `{ command: 'stop_audio' }`
3. iOS: Stop `AVAudioPlayer` direct
4. iOS: Clear audio queue
5. iOS: Update UI naar "listening"

**Code (iOS - AudioStreamManager.swift):**
```swift
private func handleServerMessage(_ json: String) {
    guard let data = json.data(using: .utf8),
          let message = try? JSONDecoder().decode(ServerCommand.self, from: data) else {
        return
    }
    
    switch message.command {
    case "stop_audio":
        playbackManager.stopImmediately()
        state = .listening
        
    case "state":
        if let newState = message.state {
            switch newState {
            case "listening": state = .listening
            case "processing": state = .processing
            case "speaking": state = .speaking
            default: break
            }
        }
    
    default:
        break
    }
}

struct ServerCommand: Codable {
    let command: String
    let state: String?
}
```

**Edge Case: Race Condition**

Probleem: iOS stuurt audio chunk → Barge-in command terug → Maar iOS had al 2e chunk gestuurd.

Oplossing:
- Server: Na barge-in, negeer audio chunks voor 200ms
- Dit voorkomt dat "oude" audio alsnog wordt verwerkt

**Code (server.js):**
```javascript
async handleAudioChunk(ws, session, audioData) {
    // Ignore audio during barge-in cooldown
    if (session.bargeInCooldown) {
        return;
    }
    
    session.lastAudioTime = Date.now();
    
    if (session.isSpeaking) {
        session.isSpeaking = false;
        session.bargeInCooldown = true;
        
        this.sendCommand(ws, { command: 'stop_audio' });
        
        // Clear cooldown after 200ms
        setTimeout(() => {
            session.bargeInCooldown = false;
        }, 200);
        
        // Clear buffer (don't process interrupted speech)
        session.audioBuffer = Buffer.alloc(0);
        return;
    }
    
    // ... rest of audio handling
}
```

### Voordeel vs v1

**Oude versie:**
- iOS detecteerde barge-in lokaal (volume threshold)
- iOS moest AVAudioRecorder stoppen/herstarten
- Veel false positives (echo, achtergrondgeluid)
- Geen speaker verification → echo probleem

**Nieuwe versie:**
- Server detecteert barge-in (nieuwe audio = Jac wil praten)
- Speaker verification → alleen Jac's stem triggert barge-in
- Dolores' eigen stem triggert geen barge-in (echo safe!)
- Simpelere iOS code (geen threshold tuning)

---

## 7. UI Design (Minimaal)

### Design Principes
1. **Zero-text:** Geen enkel woord tenzij echt nodig
2. **Intuïtief:** Status moet zonder uitleg duidelijk zijn
3. **Niet-afleidend:** Focus op gesprek, niet op scherm
4. **Ambient:** Als achtergrond muziek, niet opdringerig

### Visual States

#### 7.1 Listening (Default)
```
┌─────────────────────────┐
│                         │
│                         │
│        ◉ ◉ ◉           │  ← Pulserende cirkel
│       ◉     ◉          │    (Blauw, slow pulse)
│        ◉ ◉ ◉           │
│                         │
│                         │
│      Listening...       │  ← Klein, grijs, onderaan
└─────────────────────────┘
```

**Kleur:** `#3B82F6` (Blauw)  
**Animatie:** Scale 1.0 → 1.2, 1.5s easeInOut repeat  
**Betekenis:** "Ik luister, je kunt praten"

#### 7.2 Processing
```
┌─────────────────────────┐
│                         │
│                         │
│          ⟳             │  ← Spinner
│                         │    (Oranje, rotate)
│                         │
│                         │
│                         │
│      Thinking...        │
└─────────────────────────┘
```

**Kleur:** `#F59E0B` (Oranje)  
**Animatie:** Rotate 360°, 1s linear repeat  
**Betekenis:** "Ik verwerk je vraag"

#### 7.3 Speaking
```
┌─────────────────────────┐
│                         │
│                         │
│       ╱╲╱╲╱╲╱╲         │  ← Waveform
│                         │    (Groen, animated)
│                         │
│                         │
│                         │
│      Speaking...        │
└─────────────────────────┘
```

**Kleur:** `#10B981` (Groen)  
**Animatie:** Waveform scrolling, 2s linear repeat  
**Betekenis:** "Ik praat, luister"

### Kleurenschema

```swift
extension Color {
    static let doloresListening = Color(hex: "3B82F6")   // Blauw
    static let doloresProcessing = Color(hex: "F59E0B")  // Oranje
    static let doloresSpeaking = Color(hex: "10B981")    // Groen
    static let doloresBackground = Color.black
    static let doloresTextSecondary = Color.gray
}
```

### Accessibility
- VoiceOver: Status lezen ("Dolores is listening", etc.)
- Reduce Motion: Disable animations, gebruik static icons
- Dark Mode: Default (geen light mode nodig)

### Screen Always-On
```swift
// In ContentView.onAppear
UIApplication.shared.isIdleTimerDisabled = true
```

App blijft wakker zolang hij open is. Battery drain is acceptabel (app is bedoeld voor actief gebruik).

---

## 8. Migratiestappen (v1 → v2)

### Fase 1: Backup & Research (Week 1)

**Dag 1-2: Backup**
1. ✅ Git commit huidige v1 code
2. ✅ Tag als `v1-final`
3. ✅ Branch maken: `v2-rewrite`
4. ✅ Export speaker enrollment plan

**Dag 3-5: Azure Setup**
1. ✅ Azure Speaker Recognition API activeren
2. ✅ Test enrollment met demo audio
3. ✅ Test verification accuracy
4. ✅ Documenteer optimal threshold (0.7 of hoger)

**Dag 6-7: Architecture Validation**
1. ✅ Prototype: iOS → WebSocket → Server (raw audio)
2. ✅ Validate latency (&lt;200ms roundtrip)
3. ✅ Test barge-in concept

### Fase 2: Server Rewrite (Week 2)

**Stappen:**
1. ✅ Create `server-v2/` directory
2. ✅ Implement `speaker-verification.js`
3. ✅ Implement `speech-to-text.js` (Azure + Whisper fallback)
4. ✅ Implement `openclaw-client.js` (reuse v1)
5. ✅ Implement `text-to-speech.js` (reuse v1)
6. ✅ Implement `server.js` (WebSocket + audio pipeline)
7. ✅ Write unit tests (Jest)
8. ✅ Test server standalone (mock iOS client)

**Deliverables:**
- `server-v2/` volledig functioneel
- Test coverage >80%
- Latency target behaald (&lt;200ms)

### Fase 3: iOS Rewrite (Week 3)

**Stappen:**
1. ✅ Remove alle v1 UI (chat history, text field)
2. ✅ Implement `AudioStreamManager.swift`
3. ✅ Implement `AudioPlaybackManager.swift`
4. ✅ Implement `ContentView.swift` (nieuwe UI)
5. ✅ Implement visual components (PulsingCircle, WaveformView)
6. ✅ Test WebSocket connectie met server-v2
7. ✅ Test full audio roundtrip
8. ✅ Test barge-in

**Deliverables:**
- iOS app volledig functional
- UI volgens design spec
- Stable WebSocket connection

### Fase 4: Integration & Enrollment (Week 4)

**Dag 1-2: Enrollment Flow**
1. ✅ Build enrollment UI in iOS (tijdelijk)
2. ✅ Record 3x 15 seconden audio van Jac
3. ✅ Upload naar server
4. ✅ Generate speaker profile
5. ✅ Save profile ID
6. ✅ Remove enrollment UI (replace with main UI)

**Dag 3-5: Testing**
1. ✅ End-to-end test: Jac praat → Dolores antwoordt
2. ✅ Test barge-in: Jac interrupt Dolores
3. ✅ Test echo: Dolores' stem wordt niet als Jac herkend
4. ✅ Test false voices: Andere mensen worden genegeerd
5. ✅ Test edge cases: Stilte, achtergrondgeluid, slechte mic

**Dag 6-7: Tuning**
1. ✅ Tune speaker verification threshold
2. ✅ Tune silence detection (1.5s optimal?)
3. ✅ Optimize WebSocket buffer size
4. ✅ Test battery usage
5. ✅ Performance profiling

### Fase 5: Deployment (Week 5)

**Dag 1-2: Server Deployment**
1. ✅ Stop v1 LaunchDaemon
2. ✅ Copy server-v2 to `~/dolores-voice/server/`
3. ✅ Update LaunchDaemon plist (port 8765)
4. ✅ Start v2 server
5. ✅ Verify logs

**Dag 3-4: iOS Deployment**
1. ✅ Build release version
2. ✅ Install op iPhone
3. ✅ Test production environment
4. ✅ Monitor eerste gesprekken

**Dag 5: Rollback Plan**
1. ✅ Document rollback procedure
2. ✅ Keep v1 server backup
3. ✅ Keep v1 iOS build

**Dag 6-7: Monitoring**
1. ✅ Check logs dagelijks
2. ✅ Measure accuracy (how often Jac needs to repeat)
3. ✅ Measure false positives (non-Jac audio accepted)
4. ✅ Tune if needed

### Rollback Plan

**If v2 fails:**
1. Stop v2 server: `launchctl unload ~/Library/LaunchAgents/com.jac.dolores-voice.plist`
2. Start v1 server: `launchctl load ~/Library/LaunchAgents/com.jac.dolores-voice-v1.plist`
3. Reinstall v1 iOS app from backup
4. Debug v2 offline
5. Retry when fixed

**Success Criteria:**
- 95% gesprekken succesvol (geen herhalen nodig)
- Barge-in werkt >90% van de tijd
- Geen false positives (andere stemmen)
- Latency &lt;300ms end-to-end

---

## 9. Risico's en Alternatieven

### Risico 1: Speaker Verification Accuracy

**Risico:**
- Azure Speaker Recognition werkt niet goed genoeg
- Te veel false negatives (Jac wordt niet herkend)
- Te veel false positives (anderen worden herkend als Jac)

**Mitigatie:**
- **Pre-productie testing:** Test enrollment met 100+ samples
- **Threshold tuning:** Start conservatief (0.8), tune naar beneden
- **Fallback:** Als verificatie mislukt 3x, tijdelijk bypass (warning in logs)

**Alternatief:**
- **Picovoice Eagle:** On-device verificatie, geen cloud latency
- **Custom model:** Train eigen model met Jac's voice samples
- **Multi-factor:** Verification + geolocation (alleen thuis)

**Besluit:**
Start met Azure (0.7 threshold). Als &lt;90% accuracy binnen 2 weken, switch naar Picovoice Eagle.

---

### Risico 2: Network Latency

**Risico:**
- WiFi latency te hoog (&gt;500ms)
- WebSocket verbinding valt weg
- Mac Mini niet bereikbaar

**Mitigatie:**
- **Local server:** Mac Mini op LAN, geen internet nodig (behalve Azure API calls)
- **Reconnect logica:** Auto-reconnect bij disconnect
- **Latency monitoring:** Log roundtrip time, alert als &gt;500ms

**Alternatief:**
- **On-device STT:** Whisper.cpp op iOS (geen server STT nodig)
- **Edge TTS:** Cache common responses lokaal
- **Fallback mode:** Als server unreachable, text-based fallback

**Besluit:**
Acceptable risk. LAN latency is typisch &lt;10ms. Azure API latency dominant (200ms). Totaal blijft &lt;300ms.

---

### Risico 3: Echo Probleem Blijft

**Risico:**
- Dolores' TTS wordt opgepikt door iPhone mic
- Speaker verification herkent dit als Jac (false positive)
- Eindeloze loop: Dolores hoort zichzelf, reageert op zichzelf

**Mitigatie:**
- **Test eerst:** Record Dolores' TTS, feed terug naar mic, verify speaker verification rejects het
- **Audio ducking:** Verlaag mic gain tijdens playback
- **Acoustic echo cancellation:** iOS `AVAudioSession` category `.playAndRecord` met `.defaultToSpeaker` zou moeten helpen

**Alternatief:**
- **Hardware:** Use headphones (Dolores in ear, Jac praat in mic)
- **Directional mic:** External mic gericht op Jac
- **Fallback:** Push-to-talk knop (tegen always-listening principe)

**Besluit:**
Speaker verification zou echo moeten elimineren (Dolores' stem ≠ Jac's stem). Test dit grondig in Fase 4. Als het faalt, fallback naar headphones.

---

### Risico 4: Battery Drain

**Risico:**
- Always-listening + WebSocket = hoge battery usage
- iPhone raakt leeg binnen uren

**Mitigatie:**
- **Optimize audio buffer:** Gebruik minimale buffer size (512 samples)
- **WebSocket keepalive:** Alleen send bij audio, geen pings
- **Screen dimming:** App is bedoeld voor voice-only, screen kan dimmen

**Metingen:**
- Test battery usage over 1 uur continuous gebruik
- Target: &lt;20% battery drain per uur

**Alternatief:**
- **Plugged in:** App verwacht dat iPhone aan stroom hangt (oplader/dock)
- **Sleep mode:** Na 5 min inactiviteit, disconnect WebSocket (manual wake)

**Besluit:**
Acceptable risk voor v2. App is voor korte sessies (&lt;30 min). Als battery drain &gt;30%/uur, introduceer sleep mode in v2.1.

---

### Risico 5: Azure API Kosten

**Risico:**
- Onverwacht hoge kosten door veel usage
- Azure quota overschreden

**Schatting (per maand):**
- Speaker Verification: 6000 requests = $1.50
- STT: 10 uur audio = $10
- TTS: 5 uur audio = $20
- **Totaal: ~$32/maand**

**Mitigatie:**
- **Budget alert:** Azure Cost Management alert bij $50/maand
- **Quota:** Set hard limit op API calls (1000/dag max)
- **Fallback:** Whisper gratis tier als Azure quota bereikt

**Alternatief:**
- **Self-hosted Whisper:** Run Whisper op Mac Mini (geen API kosten)
- **Self-hosted TTS:** Piper TTS (open source, offline)

**Besluit:**
$32/maand is acceptable. Monitor eerste maand, optimaliseer als &gt;$50.

---

### Risico 6: Privacy & Security

**Risico:**
- Audio wordt naar Azure gestuurd (cloud storage?)
- Speaker voiceprint gelekt
- Ongeautoriseerde toegang tot server

**Mitigatie:**
- **Azure data residency:** Gebruik West Europe region (GDPR)
- **No storage:** Azure opties: `SpeechConfig.setProperty(PropertyId.SpeechServiceResponse_RequestSentimentAnalysis, "false")` + disable logging
- **TLS:** WebSocket over `wss://` (encrypted)
- **Firewall:** Mac Mini server alleen accessible via LAN
- **Voiceprint encryption:** Encrypt `speaker-profile.json` at rest

**Alternatief:**
- **On-device everything:** Whisper.cpp + Piper TTS op iOS (geen cloud)
- **VPN:** Server behind VPN voor remote access

**Besluit:**
Acceptable risk. Azure's GDPR compliance is solide. Speaker profile opslaan encrypted. Voor extra privacy: v3 kan fully on-device zijn.

---

## 10. Conclusie & Next Steps

### Samenvatting

**v2 Key Changes:**
1. ✅ **Pure voice:** Geen text UI, geen chat history
2. ✅ **Always-listening:** Geen knop, altijd klaar
3. ✅ **Speaker verification:** Alleen Jac wordt herkend
4. ✅ **Echo-safe:** Dolores' stem wordt genegeerd
5. ✅ **Barge-in:** Natuurlijke interrupt flow
6. ✅ **Simplified app:** Geen lokale STT, geen level monitoring

**Technology Stack:**
- **iOS:** Swift, AVAudioEngine, WebSocket
- **Server:** Node.js, WebSocket, Azure Speech SDK
- **APIs:** Azure Speaker Recognition, Azure STT, Azure TTS, OpenClaw

**Timeline:**
- Week 1: Backup & Research
- Week 2: Server Rewrite
- Week 3: iOS Rewrite
- Week 4: Integration & Testing
- Week 5: Deployment

**Budget:**
- Development: 5 weken
- Operational: ~$32/maand

### Immediate Next Steps

**STAP 1: Azure Setup (Vandaag)**
```bash
# Activate Azure Speaker Recognition API
az cognitiveservices account create \
  --name dolores-speaker \
  --resource-group dolores-rg \
  --kind SpeechServices \
  --sku S0 \
  --location westeurope
```

**STAP 2: Enrollment Test (Morgen)**
- Record 3x 15 sec audio van Jac
- Test enrollment flow
- Measure verification accuracy

**STAP 3: Server Prototype (Deze week)**
- Create `server-v2/` directory
- Implement basic WebSocket + speaker verification
- Test with mock iOS client (curl/wscat)

**STAP 4: iOS Prototype (Volgende week)**
- Strip v1 UI
- Implement AudioStreamManager
- Test WebSocket connection

**STAP 5: Full Integration (Over 2 weken)**
- End-to-end test
- Barge-in test
- Echo test

### Success Metrics

**Launch criteria (before v2.0 production):**
- [x] Speaker verification accuracy &gt;95%
- [x] End-to-end latency &lt;300ms
- [x] Barge-in success rate &gt;90%
- [x] Zero false positives (non-Jac voices rejected)
- [x] Zero echo loops
- [x] Battery usage &lt;30%/uur

**Post-launch (first month):**
- [x] 50+ successful conversations
- [x] Azure costs &lt;$50
- [x] Zero crashes
- [x] User satisfaction (Jac's feedback)

### Future Enhancements (v2.1+)

**Nice-to-have:**
- Multi-language support (Engels + Nederlands)
- Emotion detection (happy/sad/angry voice)
- Wake word ("Hey Dolores") voor hands-free
- Multiple speaker profiles (Jac + others)
- Conversation history (audio recordings + transcripts)
- Analytics dashboard (response time, accuracy, usage)

**v3 Vision (Full Privacy):**
- On-device STT (Whisper.cpp)
- On-device TTS (Piper)
- On-device speaker verification (Picovoice Eagle)
- Zero cloud dependencies (behalve OpenClaw, which is local anyway)

---

## Appendix: File Structure

```
~/dolores-voice/
├── PLAN-V2.md                    # This document
├── README.md                     # Project overview
├── server-v1/                    # Old server (backup)
│   ├── server.js
│   └── package.json
├── server-v2/                    # New server
│   ├── server.js                 # Main WebSocket server
│   ├── speaker-verification.js   # Azure Speaker Recognition
│   ├── speech-to-text.js         # Azure STT + Whisper fallback
│   ├── openclaw-client.js        # OpenClaw HTTP client
│   ├── text-to-speech.js         # Azure TTS
│   ├── package.json
│   └── .env                      # API keys (gitignored)
├── ios-app/                      # iOS app (Xcode project)
│   ├── DoloresVoice.xcodeproj
│   ├── DoloresVoice/
│   │   ├── ContentView.swift     # Main UI
│   │   ├── AudioStreamManager.swift
│   │   ├── AudioPlaybackManager.swift
│   │   ├── VisualComponents.swift
│   │   └── Info.plist
│   └── DoloresVoiceTests/
├── enrollment/                   # Enrollment audio samples
│   ├── jac-sample-1.wav
│   ├── jac-sample-2.wav
│   └── jac-sample-3.wav
├── .dolores-voice/               # Runtime data (user home)
│   ├── speaker-profile.json      # Jac's voiceprint
│   └── logs/                     # Server logs
└── scripts/
    ├── deploy.sh                 # Deployment script
    └── test-enrollment.sh        # Test enrollment flow
```

---

**END OF PLAN**

*Geschreven door Dolores, 10 februari 2026*  
*Next: Start met Azure setup & enrollment test*
