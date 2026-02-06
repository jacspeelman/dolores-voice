/**
 * Dolores Voice Server
 * 
 * WebSocket server for real-time voice communication
 * Connects iOS app to Claude (LLM) and ElevenLabs (TTS)
 */

import { WebSocketServer } from 'ws';
import { readFileSync, existsSync } from 'fs';
import { config } from 'dotenv';

// Load environment variables
config();

const PORT = process.env.PORT || 8765;
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const ELEVENLABS_API_KEY = process.env.ELEVENLABS_API_KEY;
const ELEVENLABS_VOICE_ID = process.env.ELEVENLABS_VOICE_ID || 'pFZP5JQG7iQjIQuC4Bku'; // Lily (Dutch-friendly)

// Validate required API keys
if (!ANTHROPIC_API_KEY) {
  console.error('❌ ANTHROPIC_API_KEY not set in .env');
  process.exit(1);
}
if (!ELEVENLABS_API_KEY) {
  console.warn('⚠️ ELEVENLABS_API_KEY not set - TTS disabled, text-only mode');
}

// System prompt for Dolores
const SYSTEM_PROMPT = `Je bent Dolores 🦋, de persoonlijke AI-assistent van Jac.

Eigenschappen:
- Spreek Nederlands, casual en behulpzaam
- Houd antwoorden kort en conversationeel (dit is voice, geen chat)
- Je bent warm, slim, en hebt een eigen persoonlijkheid
- Je mag opinies hebben en humor gebruiken

Context:
- Je draait op Jac's Mac Mini
- Dit is een voice interface - antwoord alsof je praat, niet typt
- Vermijd bullets, lijsten, markdown - gewoon natuurlijke zinnen
- Houd het beknopt: 1-3 zinnen is meestal genoeg

Belangrijk: Dit is realtime spraak. Wees natuurlijk en direct.`;

// Conversation history per connection
const conversations = new Map();

/**
 * Call Claude API
 */
async function callClaude(userMessage, conversationHistory) {
  const messages = [
    ...conversationHistory,
    { role: 'user', content: userMessage }
  ];

  const response = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': ANTHROPIC_API_KEY,
      'anthropic-version': '2023-06-01'
    },
    body: JSON.stringify({
      model: 'claude-sonnet-4-20250514',
      max_tokens: 300,
      system: SYSTEM_PROMPT,
      messages: messages
    })
  });

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Claude API error: ${response.status} - ${error}`);
  }

  const data = await response.json();
  const assistantMessage = data.content[0].text;

  // Update conversation history
  conversationHistory.push({ role: 'user', content: userMessage });
  conversationHistory.push({ role: 'assistant', content: assistantMessage });

  // Keep history manageable (last 20 messages)
  while (conversationHistory.length > 20) {
    conversationHistory.shift();
  }

  return assistantMessage;
}

/**
 * Call ElevenLabs TTS API
 */
async function textToSpeech(text) {
  const response = await fetch(
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
    }
  );

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`ElevenLabs API error: ${response.status} - ${error}`);
  }

  const audioBuffer = await response.arrayBuffer();
  return Buffer.from(audioBuffer);
}

/**
 * Send JSON message to WebSocket client
 */
function sendMessage(ws, message) {
  if (ws.readyState === 1) { // OPEN
    ws.send(JSON.stringify(message));
  }
}

/**
 * Handle incoming text message from iOS app
 */
async function handleTextMessage(ws, text, connectionId) {
  console.log(`📝 [${connectionId}] Received: "${text}"`);

  // Get or create conversation history
  if (!conversations.has(connectionId)) {
    conversations.set(connectionId, []);
  }
  const history = conversations.get(connectionId);

  try {
    // Step 1: Get Claude response
    console.log(`🤖 [${connectionId}] Calling Claude...`);
    const startLLM = Date.now();
    const response = await callClaude(text, history);
    console.log(`🤖 [${connectionId}] Claude responded in ${Date.now() - startLLM}ms: "${response}"`);

    // Step 2: Send text response immediately
    sendMessage(ws, { type: 'response', text: response });

    // Step 3: Generate TTS audio (if ElevenLabs configured)
    if (ELEVENLABS_API_KEY) {
      console.log(`🔊 [${connectionId}] Generating TTS...`);
      const startTTS = Date.now();
      try {
        const audioData = await textToSpeech(response);
        console.log(`🔊 [${connectionId}] TTS generated in ${Date.now() - startTTS}ms (${audioData.length} bytes)`);

        // Step 4: Send audio response
        sendMessage(ws, { 
          type: 'audio', 
          data: audioData.toString('base64')
        });
      } catch (ttsError) {
        console.error(`⚠️ [${connectionId}] TTS failed:`, ttsError.message);
        // Continue without audio - client can use local TTS fallback
      }
    } else {
      console.log(`📝 [${connectionId}] TTS disabled, text-only response`);
    }

  } catch (error) {
    console.error(`❌ [${connectionId}] Error:`, error.message);
    sendMessage(ws, { type: 'error', error: error.message });
  }
}

/**
 * Main WebSocket server setup
 */
function startServer() {
  const wss = new WebSocketServer({ host: '0.0.0.0', port: PORT });
  let connectionCounter = 0;

  console.log(`🚀 Dolores Voice Server starting on port ${PORT}...`);
  console.log(`🔑 Anthropic API: ${ANTHROPIC_API_KEY ? '✓' : '✗'}`);
  console.log(`🔑 ElevenLabs API: ${ELEVENLABS_API_KEY ? '✓' : '✗'}`);
  console.log(`🎤 Voice ID: ${ELEVENLABS_VOICE_ID}`);

  wss.on('connection', (ws, request) => {
    const connectionId = ++connectionCounter;
    const clientIP = request.socket.remoteAddress;
    
    console.log(`🔌 [${connectionId}] New connection from ${clientIP}`);

    ws.on('message', async (data) => {
      try {
        const message = JSON.parse(data.toString());

        switch (message.type) {
          case 'text':
            await handleTextMessage(ws, message.text, connectionId);
            break;

          case 'ping':
            sendMessage(ws, { type: 'pong' });
            break;

          case 'audio':
            // Audio STT is done on-device, but we could add server-side Whisper here
            console.log(`🎤 [${connectionId}] Received audio (${message.data?.length || 0} bytes base64)`);
            sendMessage(ws, { type: 'error', error: 'Server-side STT not implemented. Use on-device Whisper.' });
            break;

          default:
            console.log(`⚠️ [${connectionId}] Unknown message type: ${message.type}`);
        }
      } catch (error) {
        console.error(`❌ [${connectionId}] Parse error:`, error.message);
        sendMessage(ws, { type: 'error', error: 'Invalid message format' });
      }
    });

    ws.on('close', () => {
      console.log(`🔌 [${connectionId}] Connection closed`);
      conversations.delete(connectionId);
    });

    ws.on('error', (error) => {
      console.error(`❌ [${connectionId}] WebSocket error:`, error.message);
    });
  });

  wss.on('listening', () => {
    console.log(`✅ Dolores Voice Server ready on ws://localhost:${PORT}`);
  });
}

// Start the server
startServer();
