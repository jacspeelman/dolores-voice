# Donna Voice Server — Setup voor OpenClaw

Deze guide beschrijft hoe je de Donna Voice Server draait op de Mac mini zodat de iOS voice interface via OpenClaw communiceert.

## Architectuur

```
iPhone (Donna Voice app)
    │
    │  WebSocket (audio PCM 16kHz)
    ▼
Donna Voice Server (Node.js, poort 8765)
    │
    ├──► Deepgram (STT: spraak → tekst)
    ├──► OpenClaw (LLM: tekst → antwoord)  ◄── lokaal op dezelfde machine
    └──► ElevenLabs (TTS: antwoord → spraak)
    │
    ▼
iPhone (audio playback)
```

## Vereisten

- Node.js 18+
- npm
- OpenClaw draaiend op `http://127.0.0.1:18789` met een OpenAI-compatible `/v1/chat/completions` endpoint

## Installatie

```bash
# 1. Clone het project
git clone <repo-url> donna_voice
cd donna_voice/server

# 2. Installeer dependencies
npm install
```

## Configuratie

Maak een `.env` bestand aan in de `server/` map (of pas het bestaande aan):

```env
PORT=8765

# === LLM Backend ===
# Zet op 'openclaw' om via OpenClaw te gaan (ipv direct OpenAI)
LLM_BACKEND=openclaw
OPENCLAW_URL=http://127.0.0.1:18789
OPENCLAW_TOKEN=<jouw OpenClaw token>
OPENCLAW_MODEL=gpt-4o

# === Deepgram STT (verplicht) ===
DEEPGRAM_API_KEY=<jouw Deepgram API key>

# === ElevenLabs TTS (verplicht) ===
ELEVENLABS_API_KEY=<jouw ElevenLabs API key>
ELEVENLABS_VOICE_ID=yO6w2xlECAQRFP6pX7Hw
ELEVENLABS_MODEL=eleven_multilingual_v2

# === OpenAI (alleen nodig voor Realtime mode) ===
OPENAI_API_KEY=<jouw OpenAI key>
```

### Configuratie-opties uitleg

| Variabele | Verplicht | Beschrijving |
|-----------|-----------|-------------|
| `LLM_BACKEND` | Ja | `openclaw` of `openai` (default: `openai`) |
| `OPENCLAW_URL` | Bij openclaw | URL van de OpenClaw gateway (default: `http://127.0.0.1:18789`) |
| `OPENCLAW_TOKEN` | Bij openclaw | Bearer token voor authenticatie bij OpenClaw |
| `OPENCLAW_MODEL` | Nee | Model naam voor OpenClaw (default: waarde van `OPENAI_MODEL`, of `gpt-4o`) |
| `DEEPGRAM_API_KEY` | Ja | API key voor Deepgram spraakherkenning |
| `ELEVENLABS_API_KEY` | Ja | API key voor ElevenLabs text-to-speech |
| `ELEVENLABS_VOICE_ID` | Nee | ElevenLabs voice ID (default: `yO6w2xlECAQRFP6pX7Hw`) |
| `OPENAI_API_KEY` | Alleen realtime | Nodig als je ook de Realtime mode (WebRTC) wilt gebruiken |

## Server starten

```bash
cd server
node index.js
```

Bij succesvol opstarten zie je:

```
🚀 Donna Voice Server v2 - Pure Voice Pipeline
🔗 LLM: OpenClaw @ http://127.0.0.1:18789 (model: gpt-4o)
🎙️ STT: Deepgram Nova-3 (real-time)
🔊 TTS: ElevenLabs eleven_multilingual_v2
✅ Ready on http://0.0.0.0:8765 (WebSocket + REST)
```

## iOS app instellen

In de Donna Voice app op de iPhone:

1. Open **Settings** (tandwiel icoon)
2. Vul bij **Server Host** het IP-adres van de Mac mini in (bijv. `192.168.1.100`)
3. Vul bij **Server Port** `8765` in
4. Kies **Classic** mode (niet Realtime)

## Testen

```bash
# Health check
curl http://localhost:8765/health
# Verwacht: {"status":"ok","version":"2.1.0","modes":["classic","realtime"]}
```

## Troubleshooting

- **Server start niet op**: Controleer of poort 8765 vrij is (`lsof -i :8765`)
- **LLM errors**: Controleer of OpenClaw draait (`curl http://127.0.0.1:18789/health`)
- **Geen audio terug**: Controleer de ElevenLabs API key en of je tegoed hebt
- **iPhone kan niet verbinden**: Controleer of de Mac mini en iPhone op hetzelfde netwerk zitten en of de firewall poort 8765 doorlaat
