/**
 * Dolores Voice Server
 * 
 * WebSocket server for real-time voice communication
 * Uses Azure Neural TTS (Fenna) for natural Dutch voice
 */

import { WebSocketServer } from 'ws';
import { config } from 'dotenv';

// Load environment variables
config();

const PORT = process.env.PORT || 8765;

// Azure TTS config
const AZURE_SPEECH_KEY = process.env.AZURE_SPEECH_KEY;
const AZURE_SPEECH_REGION = process.env.AZURE_SPEECH_REGION || 'westeurope';
const AZURE_VOICE = process.env.AZURE_VOICE || 'nl-NL-FennaNeural';
const AZURE_RATE = process.env.AZURE_RATE || '+5%';      // -50% to +50%, or slow/medium/fast
const AZURE_PITCH = process.env.AZURE_PITCH || '+0%';    // -50% to +50%, or low/medium/high
const AZURE_STYLE = process.env.AZURE_STYLE || '';       // cheerful, sad, angry, friendly, etc.

// Fallback to ElevenLabs if Azure not configured
const ELEVENLABS_API_KEY = process.env.ELEVENLABS_API_KEY;
const ELEVENLABS_VOICE_ID = process.env.ELEVENLABS_VOICE_ID || 'pFZP5JQG7iQjIQuC4Bku';

// OpenAI Whisper for speech-to-text
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

// OpenClaw Gateway config
const OPENCLAW_URL = process.env.OPENCLAW_URL || 'http://127.0.0.1:18789';
const OPENCLAW_TOKEN = process.env.OPENCLAW_TOKEN;

if (!OPENCLAW_TOKEN) {
  console.error('❌ OPENCLAW_TOKEN not set');
  process.exit(1);
}

/**
 * Create fetch with timeout
 */
function fetchWithTimeout(url, options, timeoutMs = 60000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  
  return fetch(url, { ...options, signal: controller.signal })
    .finally(() => clearTimeout(timeout));
}

// Known Whisper hallucinations (appears on silent/unclear audio)
const WHISPER_HALLUCINATIONS = [
  'ondertitels ingediend door de amara.org gemeenschap',
  'ondertiteling door de amara.org community',
  'subtitles by the amara.org community',
  'thanks for watching',
  'bedankt voor het kijken',
  'subscribe to my channel',
  'like and subscribe',
];

/**
 * OpenAI Whisper Speech-to-Text
 */
async function whisperTranscribe(audioBase64) {
  if (!OPENAI_API_KEY) {
    throw new Error('OpenAI API key not configured');
  }

  // Convert base64 to buffer
  const audioBuffer = Buffer.from(audioBase64, 'base64');
  
  // Create form data with the audio file
  const formData = new FormData();
  const audioBlob = new Blob([audioBuffer], { type: 'audio/m4a' });
  formData.append('file', audioBlob, 'audio.m4a');
  formData.append('model', 'whisper-1');
  formData.append('language', 'nl');  // Dutch
  formData.append('response_format', 'text');

  const response = await fetchWithTimeout(
    'https://api.openai.com/v1/audio/transcriptions',
    {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`
      },
      body: formData
    },
    30000  // 30 second timeout
  );

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Whisper error: ${response.status} - ${error}`);
  }

  const transcript = await response.text();
  const cleaned = transcript.trim();
  
  // Filter known hallucinations
  if (WHISPER_HALLUCINATIONS.some(h => cleaned.toLowerCase().includes(h))) {
    console.log(`⚠️ Filtered Whisper hallucination: "${cleaned}"`);
    return '';
  }
  
  return cleaned;
}

/**
 * Call OpenClaw Gateway - talks to the REAL Dolores!
 */
async function callOpenClaw(userMessage) {
  // Prepend voice instruction to keep responses short
  const voiceMessage = `[VOICE] ${userMessage}

(Dit is een voice gesprek - antwoord KORT in 1-3 zinnen, geen markdown/bullets, praat natuurlijk)`;

  const response = await fetchWithTimeout(`${OPENCLAW_URL}/v1/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${OPENCLAW_TOKEN}`,
      'x-openclaw-agent-id': 'main'
    },
    body: JSON.stringify({
      model: 'openclaw',
      messages: [{ role: 'user', content: voiceMessage }],
      user: 'voice-jac'  // Stable session key
    })
  }, 90000); // 90 second timeout for LLM (tool calls can take time)

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`OpenClaw error: ${response.status} - ${error}`);
  }

  const data = await response.json();
  return data.choices[0].message.content;
}

/**
 * Azure Neural TTS - Fenna (Dutch)
 */
async function azureTTS(text) {
  const tokenUrl = `https://${AZURE_SPEECH_REGION}.api.cognitive.microsoft.com/sts/v1.0/issueToken`;
  
  // Get access token (10 second timeout)
  const tokenResponse = await fetchWithTimeout(tokenUrl, {
    method: 'POST',
    headers: {
      'Ocp-Apim-Subscription-Key': AZURE_SPEECH_KEY,
      'Content-Length': '0'
    }
  }, 10000);
  
  if (!tokenResponse.ok) {
    throw new Error(`Azure token error: ${tokenResponse.status}`);
  }
  
  const accessToken = await tokenResponse.text();
  
  // Generate speech with prosody and optional style
  const styleTag = AZURE_STYLE 
    ? `<mstts:express-as style="${AZURE_STYLE}">` 
    : '';
  const styleClose = AZURE_STYLE ? '</mstts:express-as>' : '';
  
  const ssml = `
    <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' 
           xmlns:mstts='http://www.w3.org/2001/mstts' xml:lang='nl-NL'>
      <voice name='${AZURE_VOICE}'>
        ${styleTag}
        <prosody rate='${AZURE_RATE}' pitch='${AZURE_PITCH}'>${text}</prosody>
        ${styleClose}
      </voice>
    </speak>
  `;
  
  const ttsUrl = `https://${AZURE_SPEECH_REGION}.tts.speech.microsoft.com/cognitiveservices/v1`;
  
  // Generate speech (30 second timeout)
  const ttsResponse = await fetchWithTimeout(ttsUrl, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/ssml+xml',
      'X-Microsoft-OutputFormat': 'audio-16khz-128kbitrate-mono-mp3',
      'User-Agent': 'DoloresVoice'
    },
    body: ssml
  }, 30000);
  
  if (!ttsResponse.ok) {
    const error = await ttsResponse.text();
    throw new Error(`Azure TTS error: ${ttsResponse.status} - ${error}`);
  }
  
  const audioBuffer = await ttsResponse.arrayBuffer();
  return Buffer.from(audioBuffer);
}

/**
 * ElevenLabs TTS (fallback)
 */
async function elevenLabsTTS(text) {
  const response = await fetchWithTimeout(
    `https://api.elevenlabs.io/v1/text-to-speech/${ELEVENLABS_VOICE_ID}`,
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'xi-api-key': ELEVENLABS_API_KEY
      },
      body: JSON.stringify({
        text: text,
        model_id: 'eleven_multilingual_v2',
        voice_settings: {
          stability: 0.5,
          similarity_boost: 0.75,
          style: 0.3,
          use_speaker_boost: true
        }
      })
    },
    30000 // 30 second timeout
  );

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`ElevenLabs error: ${response.status} - ${error}`);
  }

  const audioBuffer = await response.arrayBuffer();
  return Buffer.from(audioBuffer);
}

/**
 * Text to speech - tries Azure first, falls back to ElevenLabs
 */
async function textToSpeech(text) {
  if (AZURE_SPEECH_KEY) {
    return await azureTTS(text);
  } else if (ELEVENLABS_API_KEY) {
    return await elevenLabsTTS(text);
  } else {
    throw new Error('No TTS provider configured');
  }
}

function sendMessage(ws, message) {
  if (ws.readyState === 1) {
    ws.send(JSON.stringify(message));
  }
}

async function handleTextMessage(ws, text, connectionId, wantsAudio = true) {
  console.log(`📝 [${connectionId}] Jac: "${text}" (audio: ${wantsAudio})`);

  try {
    console.log(`🦋 [${connectionId}] Asking OpenClaw...`);
    const startLLM = Date.now();
    const response = await callOpenClaw(text);
    console.log(`🦋 [${connectionId}] Dolores (${Date.now() - startLLM}ms): "${response}"`);

    sendMessage(ws, { type: 'response', text: response });

    // Only generate audio if requested
    if (wantsAudio) {
      console.log(`🔊 [${connectionId}] Generating voice...`);
      const startTTS = Date.now();
      try {
        const audioData = await textToSpeech(response);
        console.log(`🔊 [${connectionId}] TTS done (${Date.now() - startTTS}ms, ${audioData.length} bytes)`);
        sendMessage(ws, { type: 'audio', data: audioData.toString('base64') });
      } catch (ttsError) {
        console.error(`⚠️ [${connectionId}] TTS failed:`, ttsError.message);
      }
    } else {
      console.log(`📝 [${connectionId}] Text-only response (no audio)`);
    }

  } catch (error) {
    console.error(`❌ [${connectionId}] Error:`, error.message);
    sendMessage(ws, { type: 'error', error: error.message });
  }
}

async function handleAudioMessage(ws, audioBase64, connectionId) {
  console.log(`🎙️ [${connectionId}] Received audio (${Math.round(audioBase64.length / 1024)}KB)`);
  
  try {
    // Transcribe with Whisper
    console.log(`🎙️ [${connectionId}] Transcribing with Whisper...`);
    const startSTT = Date.now();
    const transcript = await whisperTranscribe(audioBase64);
    console.log(`🎙️ [${connectionId}] Whisper (${Date.now() - startSTT}ms): "${transcript}"`);
    
    if (!transcript || transcript.length === 0) {
      console.log(`⚠️ [${connectionId}] Empty transcript, ignoring`);
      sendMessage(ws, { type: 'transcript', text: '' });
      return;
    }
    
    // Send transcript back to client
    sendMessage(ws, { type: 'transcript', text: transcript });
    
    // Process as text message
    await handleTextMessage(ws, transcript, connectionId);
    
  } catch (error) {
    console.error(`❌ [${connectionId}] STT Error:`, error.message);
    sendMessage(ws, { type: 'error', error: `Transcriptie mislukt: ${error.message}` });
  }
}

function startServer() {
  const wss = new WebSocketServer({ host: '0.0.0.0', port: PORT });
  let connectionCounter = 0;
  const activeConnections = new Map(); // Track active connections

  const ttsProvider = AZURE_SPEECH_KEY ? 'Azure Fenna 🇳🇱' : (ELEVENLABS_API_KEY ? 'ElevenLabs' : 'None');

  console.log(`🚀 Dolores Voice Server starting...`);
  console.log(`🔗 OpenClaw: ${OPENCLAW_URL}`);
  console.log(`🔑 Auth: ✓`);
  console.log(`🎤 TTS: ${ttsProvider}`);

  // Server-side heartbeat to detect dead connections
  const HEARTBEAT_INTERVAL = 30000; // 30 seconds
  const HEARTBEAT_TIMEOUT = 10000;  // 10 seconds to respond
  
  const heartbeatInterval = setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws.isAlive === false) {
        console.log(`💔 Connection timed out, terminating`);
        return ws.terminate();
      }
      ws.isAlive = false;
      ws.ping(); // Send ping, expect pong
    });
  }, HEARTBEAT_INTERVAL);

  wss.on('close', () => {
    clearInterval(heartbeatInterval);
  });

  wss.on('connection', (ws, request) => {
    const connectionId = ++connectionCounter;
    const clientIP = request.socket.remoteAddress;
    console.log(`🔌 [${connectionId}] Connected from ${clientIP}`);
    
    // Track connection
    ws.isAlive = true;
    ws.connectionId = connectionId;
    activeConnections.set(connectionId, { ws, connectedAt: Date.now() });

    // Handle pong responses (for heartbeat)
    ws.on('pong', () => {
      ws.isAlive = true;
    });
    
    // Send config info to client
    const ttsInfo = AZURE_SPEECH_KEY 
      ? { provider: 'Azure Speech', voice: 'Fenna', flag: '🇳🇱', rate: AZURE_RATE, pitch: AZURE_PITCH, style: AZURE_STYLE || 'default' }
      : ELEVENLABS_API_KEY 
        ? { provider: 'ElevenLabs', voice: 'Custom', flag: '🎭' }
        : { provider: 'None', voice: '-', flag: '❌' };
    
    sendMessage(ws, { 
      type: 'config', 
      tts: ttsInfo,
      stt: OPENAI_API_KEY ? { provider: 'Whisper', flag: '🎙️' } : { provider: 'Local', flag: '📱' },
      region: AZURE_SPEECH_REGION || 'n/a',
      backend: 'OpenClaw'  // De echte Dolores!
    });

    ws.on('message', async (data) => {
      ws.isAlive = true; // Any message counts as alive
      try {
        const message = JSON.parse(data.toString());
        if (message.type === 'text') {
          const wantsAudio = message.wantsAudio !== false; // Default true for backwards compatibility
          await handleTextMessage(ws, message.text, connectionId, wantsAudio);
        } else if (message.type === 'audio') {
          await handleAudioMessage(ws, message.data, connectionId);
        } else if (message.type === 'ping') {
          sendMessage(ws, { type: 'pong' });
        }
      } catch (error) {
        console.error(`❌ [${connectionId}] Message error:`, error.message);
        sendMessage(ws, { type: 'error', error: 'Invalid message' });
      }
    });

    ws.on('error', (error) => {
      console.error(`⚠️ [${connectionId}] WebSocket error:`, error.message);
    });

    ws.on('close', (code, reason) => {
      const reasonStr = reason ? reason.toString() : 'no reason';
      console.log(`🔌 [${connectionId}] Disconnected (code: ${code}, reason: ${reasonStr})`);
      activeConnections.delete(connectionId);
    });
  });

  wss.on('listening', () => {
    console.log(`✅ Ready on ws://0.0.0.0:${PORT}`);
  });

  wss.on('error', (error) => {
    console.error(`❌ Server error:`, error.message);
  });
}

startServer();
