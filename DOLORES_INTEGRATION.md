# Dolores Voice v2 - Integration Guide

This document describes how to connect the Dolores Voice server to the Dolores/OpenClaw backend instead of the default OpenAI API fallback.

## Architecture Overview

```
iPhone App  <──WebSocket──>  Node.js Server  <──HTTP/SSE──>  LLM Backend
(mic + speaker)              (orchestrator)                  (Dolores brain)
                                  │
                          Deepgram STT (streaming)
                          ElevenLabs TTS (streaming)
```

The server acts as an orchestrator:
1. Receives raw PCM audio from the iPhone via WebSocket
2. Streams it to Deepgram for real-time speech-to-text
3. Sends the transcript to the LLM backend (currently OpenAI, should be OpenClaw)
4. Streams the LLM response text to ElevenLabs for text-to-speech
5. Sends PCM audio back to the iPhone for playback

## How to Replace OpenAI with OpenClaw

The LLM integration lives in **one function** in `server/index.js`: the `callLLM()` async generator.

### Current OpenAI implementation

```javascript
async function* callLLM(userMessage) {
  const response = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${OPENAI_API_KEY}`
    },
    body: JSON.stringify({
      model: 'gpt-4o',
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: userMessage }
      ],
      stream: true
    })
  });

  // Parses SSE stream, yields text chunks
  // ...
}
```

### What OpenClaw needs to provide

The `callLLM(userMessage)` function is an **async generator** that must:

1. Accept a `userMessage` string (the user's spoken words, transcribed)
2. Send it to the LLM backend
3. **Yield text chunks** as they arrive (streaming is important for low latency)
4. The yielded text is split into sentences and each sentence is sent to ElevenLabs TTS immediately

### Option A: OpenClaw with OpenAI-compatible API

If OpenClaw exposes an OpenAI-compatible `/v1/chat/completions` endpoint with SSE streaming, just change the URL and auth:

```javascript
// In .env:
OPENCLAW_URL=http://192.168.1.214:18789
OPENCLAW_TOKEN=your-token-here

// In server/index.js, replace callLLM:
async function* callLLM(userMessage) {
  const response = await fetchWithTimeout(`${process.env.OPENCLAW_URL}/v1/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${process.env.OPENCLAW_TOKEN}`
    },
    body: JSON.stringify({
      messages: [{ role: 'user', content: userMessage }],
      stream: true
    })
  }, 30000);

  if (!response.ok) {
    throw new Error(`OpenClaw error: ${response.status}`);
  }

  // Parse SSE stream (same as OpenAI format)
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split('\n');
    buffer = lines.pop();

    for (const line of lines) {
      if (line.startsWith('data: ')) {
        const data = line.slice(6).trim();
        if (data === '[DONE]') return;
        try {
          const json = JSON.parse(data);
          const delta = json.choices?.[0]?.delta?.content;
          if (delta) yield delta;
        } catch (e) {}
      }
    }
  }
}
```

### Option B: OpenClaw with custom API

If OpenClaw has a different API format, adapt `callLLM` to match. The only requirement is that it **yields text strings** as they become available:

```javascript
async function* callLLM(userMessage) {
  const response = await fetchWithTimeout(`${process.env.OPENCLAW_URL}/your/endpoint`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${process.env.OPENCLAW_TOKEN}`
    },
    body: JSON.stringify({
      message: userMessage,
      // ... whatever OpenClaw expects
    })
  }, 30000);

  // Adapt parsing to OpenClaw's response format
  // Key: yield text chunks as they arrive
  yield "Dit is een voorbeeld.";
}
```

### Option C: Non-streaming (simpler but slower)

If OpenClaw doesn't support streaming, you can yield the entire response at once. This will work but TTS will only start after the full response is generated:

```javascript
async function* callLLM(userMessage) {
  const response = await fetchWithTimeout(`${process.env.OPENCLAW_URL}/chat`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: userMessage })
  }, 30000);

  const data = await response.json();
  yield data.response; // Single yield with full text
}
```

## Environment Variables

The server reads these from `server/.env`:

| Variable | Required | Description |
|---|---|---|
| `PORT` | No | WebSocket port (default: 8765) |
| `DEEPGRAM_API_KEY` | Yes | Deepgram API key for STT |
| `ELEVENLABS_API_KEY` | Yes | ElevenLabs API key for TTS |
| `ELEVENLABS_VOICE_ID` | No | Voice ID (default: yO6w2xlECAQRFP6pX7Hw) |
| `OPENAI_API_KEY` | Yes* | OpenAI API key (*not needed if using OpenClaw) |
| `OPENCLAW_URL` | No | OpenClaw gateway URL |
| `OPENCLAW_TOKEN` | No | OpenClaw auth token |

## Voice Pipeline Details

### Audio Format
- PCM S16LE (signed 16-bit little-endian)
- 16kHz sample rate
- Mono (1 channel)
- Base64 encoded over WebSocket

### Speech-to-Text (Deepgram)
- Model: Nova-3
- Language: Dutch (nl)
- Streaming with `utterance_end_ms: 1500` (waits 1.5s of silence before finalizing)
- `endpointing: 500` (segments finalized after 500ms pause, but processing waits for UtteranceEnd)

### Text-to-Speech (ElevenLabs)
- Model: eleven_multilingual_v2
- Output: pcm_16000 (raw PCM, no MP3 header)
- Sentences are TTS'd serially (one at a time) to avoid 429 rate limits
- First sentence starts TTS while LLM is still streaming

### Echo Loop Prevention
The main challenge is preventing the mic from picking up TTS speaker output:
1. Deepgram STT session is **killed** when processing starts (`stopSTT()`)
2. A new STT session is created only after the iPhone sends `playback_done`
3. `playback_done` is sent after audio truly finishes playing on device (not at `audio_end`)
4. Short 500ms mute window after playback for residual reverb

## WebSocket Protocol

### Client -> Server
```json
{"type": "audio", "data": "<base64 PCM>"}
{"type": "playback_done"}
{"type": "interrupt"}
```

### Server -> Client
```json
{"type": "state", "state": "listening|processing|speaking"}
{"type": "audio", "format": "pcm_s16le", "sampleRate": 16000, "channels": 1, "data": "<base64 PCM>"}
{"type": "audio_end"}
{"type": "transcript", "text": "..."}
{"type": "error", "error": "..."}
```

## Running Locally

```bash
# Start server
cd server
npm install
cp .env.example .env  # Fill in API keys
node index.js

# Build iOS app
# Open ios/DoloresVoice.xcodeproj in Xcode
# Set server URL in VoiceManager.swift (line ~204)
# Build and run on iPhone
```

The iPhone must be on the same network as the server. Update `serverURL` in `VoiceManager.swift` to your server's local IP.
