# Dolores Voice Server v2 - Pure Voice Pipeline

Complete rewrite voor pure voice interaction zonder chat UI.

## 🎯 Wat is nieuw in v2?

### Audio Pipeline
1. **iOS app** → raw PCM audio (16-bit, 16kHz mono)
2. **Speaker Verification** (Azure) → check of het Jac is *(optioneel)*
3. **STT** (Deepgram Nova-3) → real-time streaming transcriptie
4. **AI** (OpenClaw) → Dolores antwoordt
5. **TTS** (ElevenLabs) → natuurlijke Nederlandse stem
6. **iOS app** ← audio chunks

### Features
- ✅ **Real-time STT streaming** met Deepgram Nova-3
- ✅ **Barge-in support** - interrupt tijdens spraak
- ✅ **State management** - listening/processing/speaking
- ✅ **Speaker verification** - voorkom Dolores' eigen stem als trigger
- ✅ **Sentence-based TTS** - begin spraak zo snel mogelijk
- ✅ **OpenClaw integration** - bestaande agent blijft werken

## 📋 Requirements

### Credentials Nodig

1. **Deepgram API Key** (REQUIRED)
   - Sign up: https://console.deepgram.com/
   - Create API key
   - Add to `.env`: `DEEPGRAM_API_KEY=your_key_here`

2. **ElevenLabs API Key** (REQUIRED)
   - Already configured: `sk_c277...`
   - Voice ID voor Jac: `yO6w2xlECAQRFP6pX7Hw`
   - Model: `eleven_multilingual_v2`

3. **Azure Speaker Verification** (OPTIONAL)
   - Voor productie: voorkom Dolores' eigen stem als trigger
   - Setup vereist:
     - Azure Speech resource aanmaken
     - Speaker profile voor Jac's stem
     - Environment variables:
       - `AZURE_SPEAKER_KEY`
       - `AZURE_SPEAKER_REGION`
       - `AZURE_SPEAKER_PROFILE_ID`
   - Als niet geconfigureerd: server skipped verification

4. **OpenClaw** (Already configured)
   - Gateway: `http://127.0.0.1:18789`
   - Token: `3045cdeb...`

## 🚀 Installation

```bash
cd ~/dolores-voice/server
npm install
```

## ⚙️ Configuration

Edit `.env`:

```bash
# === V2 REQUIRED ===
DEEPGRAM_API_KEY=your_deepgram_key_here

# === Already configured ===
ELEVENLABS_API_KEY=sk_c2774...
ELEVENLABS_VOICE_ID=yO6w2xlECAQRFP6pX7Hw
OPENCLAW_TOKEN=3045cdeb...

# === Optional ===
# AZURE_SPEAKER_KEY=...
# AZURE_SPEAKER_REGION=westeurope
# AZURE_SPEAKER_PROFILE_ID=...
```

## 🎮 Usage

### Start Server

```bash
node index.js
```

Expected output:
```
🚀 Dolores Voice Server v2 - Pure Voice Pipeline
🔗 OpenClaw: http://127.0.0.1:18789
🎙️ STT: Deepgram Nova-3 (real-time)
🔊 TTS: ElevenLabs eleven_multilingual_v2 (voice: yO6w2xlE...)
🔐 Speaker Verification: disabled
✅ Ready on ws://0.0.0.0:8765
```

### LaunchDaemon (Production)

De bestaande `ai.dolores.voice` LaunchDaemon blijft werken:

```bash
# Restart service met nieuwe v2 server
launchctl stop ai.dolores.voice
launchctl start ai.dolores.voice

# Check logs
tail -f ~/dolores-voice/server/logs/voice-server.log
```

## 📡 WebSocket Protocol

### Client → Server

**Audio Stream:**
```json
{
  "type": "audio",
  "data": "<base64 PCM 16-bit 16kHz mono>"
}
```

**Interrupt (Barge-in):**
```json
{
  "type": "interrupt"
}
```

### Server → Client

**State Updates:**
```json
{
  "type": "state",
  "state": "listening|processing|speaking"
}
```

**Audio Response:**
```json
{
  "type": "audio",
  "data": "<base64 mp3>",
  "index": 0
}
```

**Audio End:**
```json
{
  "type": "audio_end"
}
```

**Transcript (Logging):**
```json
{
  "type": "transcript",
  "text": "wat Jac zei"
}
```

## 🔧 Testing

### 1. Start Server
```bash
node index.js
```

### 2. Check Deepgram Connection
Server should connect to Deepgram when first audio arrives. Look for:
```
🎙️ [1] Deepgram connection opened
```

### 3. Check ElevenLabs
When response arrives, server generates speech:
```
🔊 [1] TTS starting for sentence 1: "Hoi Jac, hoe gaat het?"
🔊 [1] Sent audio chunk 0 (45823 bytes)
```

### 4. Test Barge-in
Send `{type: "interrupt"}` tijdens spraak:
```
⏸️ [1] User interrupted
⏸️ [1] Interrupted, clearing audio queue
```

## 🐛 Troubleshooting

### "DEEPGRAM_API_KEY not set"
→ Add Deepgram key to `.env`

### "ELEVENLABS_API_KEY not set"
→ Should already be configured, check `.env`

### "Deepgram connection timeout"
→ Check internet connection
→ Verify Deepgram API key is valid

### "Speaker verification not configured"
→ This is OK! Verification is optional
→ For production, set up Azure Speaker Recognition

### "Failed to start STT"
→ Check Deepgram API quota
→ Check audio format (must be PCM 16-bit 16kHz mono)

## 📊 Differences from v1

| Feature | v1 | v2 |
|---------|----|----|
| **UI** | Chat interface | Pure voice |
| **STT** | Azure Speech (batch) | Deepgram Nova-3 (streaming) |
| **TTS** | Azure Fenna | ElevenLabs multilingual |
| **Speaker ID** | None | Azure (optional) |
| **Barge-in** | No | Yes |
| **Streaming** | Text only | Text + Audio |
| **State** | Implicit | Explicit (listening/processing/speaking) |

## 🎯 Next Steps (Voor Jac)

1. ✅ **Get Deepgram API Key**
   - https://console.deepgram.com/
   - Add to `.env`

2. ⚠️ **Test with iOS app**
   - Update app to use v2 protocol
   - Test barge-in
   - Test state management

3. 🔒 **Optional: Azure Speaker Verification**
   - Create Azure Speech resource
   - Record voice samples
   - Create speaker profile
   - Add credentials to `.env`

## 📝 Notes

- **Port blijft 8765** - geen iOS app changes nodig voor URL
- **LaunchDaemon blijft werken** - alleen server code is veranderd
- **OpenClaw integratie intact** - zelfde agent, zelfde context
- **Speaker verification is optioneel** - server werkt ook zonder

## 🚨 Security

Deze credentials zijn al in de code (masked hier):
- ❌ **NIET committen naar git!**
- ❌ **NIET delen in screenshots!**
- ✅ `.env` staat in `.gitignore`

## 📚 API Documentation

### Deepgram
- Docs: https://developers.deepgram.com/
- Model: Nova-3 (best multilingual accuracy)
- Language: Dutch (nl)

### ElevenLabs
- Docs: https://elevenlabs.io/docs
- Model: eleven_multilingual_v2
- Voice: Jac's custom voice ID

### OpenClaw
- Internal gateway
- Already integrated
- Voice prefix: `[VOICE]` voor context
