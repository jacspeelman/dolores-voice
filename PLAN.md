# Donna Voice App — Projectplan v2

**Doel:** Native iOS app voor natuurlijke spraakcommunicatie met Donna, beveiligd en wereldwijd bereikbaar.

**Scope:** Persoonlijk project voor Jac — geen product, alleen jouw iPhone.

*Laatste update: 5 februari 2026 — verwerkt feedback van Claude, GPT-4o en Grok*

---

## 🎯 Vereisten

1. **Natuurlijke spraak** — zo vloeiend als mens-mens gesprek
2. **Native iOS app** — Swift/SwiftUI
3. **Vast IP** — bereikbaar overal ter wereld
4. **Maximale security** — alleen jouw device kan verbinden
5. **Privacy** — geen data naar derden waar mogelijk
6. **Robuustheid** — fallbacks voor wanneer cloud/netwerk faalt

---

## 🏗️ Architectuur

```
┌─────────────────┐         ┌─────────────────────────────┐
│   iPhone App    │◄───────►│   Mac Mini (Donna)        │
│                 │  mTLS    │                             │
│  ┌───────────┐  │  over    │  ┌───────────────────────┐  │
│  │ Whisper   │  │  WS      │  │ OpenClaw Gateway      │  │
│  │ (STT)     │  │         │  │                       │  │
│  └───────────┘  │         │  │  ┌─────────────────┐  │  │
│                 │         │  │  │ Voice API       │  │  │
│  ┌───────────┐  │         │  │  │ (WebSocket)     │  │  │
│  │ TTS       │◄─┼─────────┼──┼──┤                 │  │  │
│  │ Primary:  │  │         │  │  └────────┬────────┘  │  │
│  │ ElevenLabs│  │         │  │           │           │  │
│  │ Fallback: │  │         │  │  ┌────────▼────────┐  │  │
│  │ AVSpeech  │  │         │  │  │ Claude (LLM)    │  │  │
│  └───────────┘  │         │  │  │ via Anthropic   │  │  │
│                 │         │  │  └────────┬────────┘  │  │
│  ┌───────────┐  │         │  │           │           │  │
│  │ Keychain  │  │         │  │  ┌────────▼────────┐  │  │
│  │ (certs)   │  │         │  │  │ TTS Engine      │  │  │
│  └───────────┘  │         │  │  │ (ElevenLabs)    │  │  │
│                 │         │  │  └─────────────────┘  │  │
└─────────────────┘         │  └───────────────────────┘  │
        │                   │                             │
        │ Internet          │  ┌───────────────────────┐  │
        │                   │  │ Nginx/Caddy           │  │
        └──────────────────►│  │ (reverse proxy+mTLS)  │  │
          VPS (vast IP)     │  └───────────────────────┘  │
          + WireGuard       └─────────────────────────────┘
```

---

## 🧠 LLM Laag (toegevoegd na review)

**Model:** Claude (via OpenClaw Gateway)
- Dezelfde Donna die je nu via Telegram spreekt
- Geen extra API nodig — OpenClaw handelt dit af
- Context/memory blijft behouden

**Latency budget:**
- STT: 200-500ms
- Network: 50-100ms
- LLM (Claude): 500-2000ms
- TTS: 200-300ms
- **Totaal: ~1-3 seconden**

**Optimalisatie (streaming):**
- Begin TTS zodra eerste LLM tokens binnen zijn
- Sentence-level streaming → drastisch lagere perceived latency
- Target: <1s tot eerste audio

---

## 🔐 Security Model

### Authenticatie: Mutual TLS (mTLS)
- **Server certificaat:** Mac Mini bewijst identiteit aan app
- **Client certificaat:** App bewijst identiteit aan server
- Zonder geldig client cert → geen toegang
- Certificaten in iOS Keychain (Secure Enclave)

### Extra lagen:
- **Certificate pinning** — app accepteert alleen jouw server cert
- **API token** — extra laag bovenop mTLS
- **Rate limiting** — bescherming tegen brute force

### Certificate management:
- Korte lifetime (90 dagen) + auto-renewal
- Revocation plan bij device verlies
- Backup cert procedure

### Waarom mTLS?
- Sterker dan API keys alleen
- Standaard enterprise security
- Client cert kan niet worden onderschept zoals wachtwoord
- Revocable: certificaat intrekken = toegang weg

---

## 🎙️ Spraak Componenten

### Speech-to-Text (STT)
**Primair: Whisper on-device**
- Whisper via CoreML — Apple Silicon optimized
- Latency: ~200-500ms
- Privacy: audio verlaat device niet
- Model: whisper-small (~500MB) of whisper-base (~150MB)

**Alternatief (later):** Apple Speech Framework
- Sneller (~50ms)
- Minder accuraat
- Goede fallback optie

### Text-to-Speech (TTS)
**Primair: ElevenLabs**
- Meest natuurlijke stem
- Custom voice mogelijk
- Cloud-based, ~200ms latency
- Kosten: ~€5-22/maand

**Fallback: AVSpeechSynthesizer** ⚠️ *Toegevoegd na review*
- Altijd beschikbaar (iOS native)
- Geen netwerk nodig
- Minder natuurlijk, maar app blijft werken
- Automatische switch bij:
  - ElevenLabs timeout (>3s)
  - Netwerk offline
  - API errors

---

## 🌐 Netwerk Setup

### VPS + WireGuard Tunnel (aanbevolen)
```
iPhone → VPS (vast IP) → WireGuard tunnel → Mac Mini
```
- Huur kleine VPS (~€5/maand) met vast IP
- WireGuard VPN tunnel naar Mac Mini
- VPS proxied alleen verkeer (geen data opslag)
- Mac Mini IP blijft privé

### Reconnect Logic ⚠️ *Toegevoegd na review*
- Automatic reconnect met exponential backoff
- Health check elke 30s
- Graceful degradation bij tunnel drop:
  - Queue messages lokaal
  - Retry in background
  - Notificatie naar gebruiker bij langdurige outage

### VPS Hardening:
- Alleen WireGuard port open
- fail2ban actief
- Auto-updates enabled
- Minimal services

---

## 📱 iOS App Componenten

### Core Features
1. **Audio capture** — AVAudioEngine voor low-latency opname
2. **STT processing** — Whisper on-device via CoreML
3. **WebSocket client** — real-time communicatie met auto-reconnect
4. **Audio playback** — streaming TTS response
5. **Secure storage** — Keychain voor certificaten
6. **Fallback handling** — automatische switch naar AVSpeech

### UI/UX
- Minimalistisch design
- Push-to-talk als start (simpeler, betrouwbaarder)
- Later: Voice Activity Detection
- Waveform visualisatie
- Connection status indicator
- Settings: server URL, voice settings

### Frameworks
- **SwiftUI** — moderne UI
- **AVFoundation** — audio
- **Network.framework** — WebSocket + TLS
- **CoreML** — on-device ML (Whisper)
- **Security.framework** — Keychain, certificates

---

## 🚀 Implementatie Fases

### Fase 1: Proof of Concept (2-3 weken)
- [ ] Simpele iOS app met audio opname
- [ ] Whisper on-device transcriptie testen
- [ ] WebSocket verbinding naar Mac Mini
- [ ] TTS playback (ElevenLabs)
- [ ] Basis flow: praten → tekst → Donna → tekst → spraak
- [ ] AVSpeechSynthesizer fallback

### Fase 2: Security (1-2 weken)
- [ ] mTLS implementeren
- [ ] Certificate pinning
- [ ] VPS + WireGuard tunnel opzetten
- [ ] Vast IP configureren
- [ ] Cert rotation plan

### Fase 3: Polish (2-3 weken)
- [ ] Streaming TTS (sentence-level)
- [ ] Reconnect logic + health checks
- [ ] Error handling
- [ ] Connection status UI
- [ ] Voice Activity Detection (optioneel)

### Fase 4: Extras (ongoing)
- [ ] Custom wake word ("Hey Donna")
- [ ] Widget voor snelle toegang
- [ ] Conversation memory in app

**Totale geschatte tijd: 6-8 weken**

---

## 💰 Geschatte Kosten

**Eenmalig:**
- Apple Developer Account: €99/jaar
- Domain (optioneel): €10/jaar

**Maandelijks:**
- VPS (vast IP): ~€5
- ElevenLabs TTS: ~€5-22

**Totaal: ~€10-30/maand**

---

## 🛠️ Tech Stack

**iOS App:**
- SwiftUI (UI)
- Whisper CoreML (STT)
- AVFoundation (audio)
- Network.framework (WebSocket + mTLS)

**Backend (Mac Mini):**
- OpenClaw Gateway
- Claude (LLM)
- ElevenLabs API (TTS)
- Nginx/Caddy (reverse proxy)
- WireGuard (tunnel)

**Infrastructuur:**
- VPS met vast IP
- WireGuard tunnel

---

## ❓ Open Vragen

1. **Push-to-talk of hands-free?**
   - Start met push-to-talk (simpeler)
   - VAD toevoegen in Fase 3

2. **Wil je mij kunnen onderbreken mid-zin?**
   - Vereist duplex audio + interrupt detection
   - Kan in Fase 3

3. **Moet de app ook tekst kunnen tonen?**
   - Handig voor verificatie/noisy environments
   - Makkelijk toe te voegen

---

## 📅 Volgende Stappen

1. **Jac:** Beslissen op open vragen
2. **Donna:** VPS + WireGuard tunnel opzetten
3. **Donna:** Voice API endpoint bouwen op Mac Mini
4. **Samen:** iOS app ontwikkelen (ik schrijf code, jij test)

---

## 📝 Changelog

**v2 (5 feb 2026):**
- LLM laag toegevoegd (was ontbrekend)
- TTS fallback (AVSpeechSynthesizer) expliciet gemaakt
- Reconnect logic voor WireGuard toegevoegd
- Streaming architectuur beschreven
- Timeline aangepast: 4-5w → 6-8w
- Certificate management toegevoegd
- Scope verduidelijkt: persoonlijk project

**v1 (5 feb 2026):**
- Initieel plan

---

*Status: Ready for implementation*
