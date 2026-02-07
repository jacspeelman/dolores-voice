/**
 * Dolores Voice Server
 * 
 * WebSocket server for real-time voice communication
 * Uses Azure Neural TTS (Fenna) for natural Dutch voice
 * 
 * v2: Streaming support for text and audio
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
const AZURE_RATE = process.env.AZURE_RATE || '+5%';
const AZURE_PITCH = process.env.AZURE_PITCH || '+0%';
const AZURE_STYLE = process.env.AZURE_STYLE || '';

// Fallback to ElevenLabs if Azure not configured
const ELEVENLABS_API_KEY = process.env.ELEVENLABS_API_KEY;
const ELEVENLABS_VOICE_ID = process.env.ELEVENLABS_VOICE_ID || 'pFZP5JQG7iQjIQuC4Bku';

// OpenAI Whisper for speech-to-text
const OPENAI_API_KEY = process.env.OPENAI_API_KEY;

// OpenClaw Gateway config
const OPENCLAW_URL = process.env.OPENCLAW_URL || 'http://127.0.0.1:18789';
const OPENCLAW_TOKEN = process.env.OPENCLAW_TOKEN;

// Streaming config
const ENABLE_STREAMING = process.env.ENABLE_STREAMING !== 'false'; // Default true

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

// Known Whisper hallucinations
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

  const audioBuffer = Buffer.from(audioBase64, 'base64');
  
  const formData = new FormData();
  const audioBlob = new Blob([audioBuffer], { type: 'audio/m4a' });
  formData.append('file', audioBlob, 'audio.m4a');
  formData.append('model', 'whisper-1');
  formData.append('language', 'nl');
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
    30000
  );

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Whisper error: ${response.status} - ${error}`);
  }

  const transcript = await response.text();
  const cleaned = transcript.trim();
  
  if (WHISPER_HALLUCINATIONS.some(h => cleaned.toLowerCase().includes(h))) {
    console.log(`⚠️ Filtered Whisper hallucination: "${cleaned}"`);
    return '';
  }
  
  return cleaned;
}

/**
 * Detect sentence boundaries for streaming TTS
 */
function extractCompleteSentences(text) {
  // Match sentences ending with . ! ? followed by space or end
  const sentenceRegex = /[^.!?]*[.!?]+(?:\s|$)/g;
  const sentences = [];
  let match;
  let lastIndex = 0;
  
  while ((match = sentenceRegex.exec(text)) !== null) {
    sentences.push(match[0].trim());
    lastIndex = match.index + match[0].length;
  }
  
  const remaining = text.slice(lastIndex).trim();
  return { sentences, remaining };
}

/**
 * Call OpenClaw Gateway with streaming
 */
async function* callOpenClawStreaming(userMessage) {
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
      user: 'voice-jac',
      stream: true
    })
  }, 90000);

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`OpenClaw error: ${response.status} - ${error}`);
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    buffer += decoder.decode(value, { stream: true });
    
    // Process SSE lines
    const lines = buffer.split('\n');
    buffer = lines.pop(); // Keep incomplete line in buffer

    for (const line of lines) {
      if (line.startsWith('data: ')) {
        const data = line.slice(6).trim();
        if (data === '[DONE]') return;
        
        try {
          const json = JSON.parse(data);
          const delta = json.choices?.[0]?.delta?.content;
          if (delta) {
            yield delta;
          }
        } catch (e) {
          // Skip malformed JSON
        }
      }
    }
  }
}

/**
 * Call OpenClaw Gateway - non-streaming fallback
 */
async function callOpenClaw(userMessage) {
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
      user: 'voice-jac'
    })
  }, 90000);

  if (!response.ok) {
    const error = await response.text();
    throw new Error(`OpenClaw error: ${response.status} - ${error}`);
  }

  const data = await response.json();
  return data.choices[0].message.content;
}

/**
 * Get Azure TTS access token
 */
let azureTokenCache = { token: null, expiry: 0 };

async function getAzureToken() {
  // Tokens are valid for 10 minutes, cache for 9
  if (azureTokenCache.token && Date.now() < azureTokenCache.expiry) {
    return azureTokenCache.token;
  }

  const tokenUrl = `https://${AZURE_SPEECH_REGION}.api.cognitive.microsoft.com/sts/v1.0/issueToken`;
  
  const response = await fetchWithTimeout(tokenUrl, {
    method: 'POST',
    headers: {
      'Ocp-Apim-Subscription-Key': AZURE_SPEECH_KEY,
      'Content-Length': '0'
    }
  }, 10000);
  
  if (!response.ok) {
    throw new Error(`Azure token error: ${response.status}`);
  }
  
  const token = await response.text();
  azureTokenCache = { token, expiry: Date.now() + 9 * 60 * 1000 };
  return token;
}

/**
 * Azure Neural TTS - returns full audio buffer
 */
async function azureTTS(text) {
  const accessToken = await getAzureToken();
  
  const styleTag = AZURE_STYLE 
    ? `<mstts:express-as style="${AZURE_STYLE}">` 
    : '';
  const styleClose = AZURE_STYLE ? '</mstts:express-as>' : '';
  
  const ssml = `
    <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' 
           xmlns:mstts='http://www.w3.org/2001/mstts' xml:lang='nl-NL'>
      <voice name='${AZURE_VOICE}'>
        ${styleTag}
        <prosody rate='${AZURE_RATE}' pitch='${AZURE_PITCH}'>${escapeXml(text)}</prosody>
        ${styleClose}
      </voice>
    </speak>
  `;
  
  const ttsUrl = `https://${AZURE_SPEECH_REGION}.tts.speech.microsoft.com/cognitiveservices/v1`;
  
  const response = await fetchWithTimeout(ttsUrl, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/ssml+xml',
      'X-Microsoft-OutputFormat': 'audio-16khz-128kbitrate-mono-mp3',
      'User-Agent': 'DoloresVoice'
    },
    body: ssml
  }, 30000);
  
  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Azure TTS error: ${response.status} - ${error}`);
  }
  
  const audioBuffer = await response.arrayBuffer();
  return Buffer.from(audioBuffer);
}

/**
 * Azure TTS with streaming - yields audio chunks
 */
async function* azureTTSStreaming(text) {
  const accessToken = await getAzureToken();
  
  const styleTag = AZURE_STYLE 
    ? `<mstts:express-as style="${AZURE_STYLE}">` 
    : '';
  const styleClose = AZURE_STYLE ? '</mstts:express-as>' : '';
  
  const ssml = `
    <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' 
           xmlns:mstts='http://www.w3.org/2001/mstts' xml:lang='nl-NL'>
      <voice name='${AZURE_VOICE}'>
        ${styleTag}
        <prosody rate='${AZURE_RATE}' pitch='${AZURE_PITCH}'>${escapeXml(text)}</prosody>
        ${styleClose}
      </voice>
    </speak>
  `;
  
  const ttsUrl = `https://${AZURE_SPEECH_REGION}.tts.speech.microsoft.com/cognitiveservices/v1`;
  
  const response = await fetchWithTimeout(ttsUrl, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${accessToken}`,
      'Content-Type': 'application/ssml+xml',
      'X-Microsoft-OutputFormat': 'audio-16khz-32kbitrate-mono-mp3', // Smaller chunks
      'User-Agent': 'DoloresVoice'
    },
    body: ssml
  }, 30000);
  
  if (!response.ok) {
    const error = await response.text();
    throw new Error(`Azure TTS error: ${response.status} - ${error}`);
  }
  
  const reader = response.body.getReader();
  
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    yield Buffer.from(value);
  }
}

/**
 * Escape XML special characters
 */
function escapeXml(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
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
    30000
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

/**
 * Handle text message with streaming support
 */
async function handleTextMessageStreaming(ws, text, connectionId, wantsAudio = true) {
  console.log(`📝 [${connectionId}] Jac: "${text}" (audio: ${wantsAudio}, streaming: true)`);

  try {
    console.log(`🦋 [${connectionId}] Asking OpenClaw (streaming)...`);
    const startLLM = Date.now();
    
    let fullResponse = '';
    let sentenceBuffer = '';
    let sentenceCount = 0;
    let audioChunkIndex = 0;
    let audioSent = false;
    
    // Queue for ordered audio sending (TTS may complete out of order)
    const audioResults = [];
    let nextAudioToSend = 0;
    
    // Function to send audio chunks in order as they become ready
    const trySendAudioChunks = () => {
      while (audioResults[nextAudioToSend] !== undefined) {
        const audioData = audioResults[nextAudioToSend];
        if (audioData) {
          if (!audioSent) {
            sendMessage(ws, { type: 'audio_start' });
            audioSent = true;
          }
          sendMessage(ws, { 
            type: 'audio_chunk', 
            data: audioData.toString('base64'),
            index: nextAudioToSend
          });
          console.log(`🔊 [${connectionId}] Sent audio chunk ${nextAudioToSend + 1} (${audioData.length} bytes)`);
        }
        nextAudioToSend++;
      }
    };
    
    // Stream text from OpenClaw
    for await (const chunk of callOpenClawStreaming(text)) {
      fullResponse += chunk;
      sentenceBuffer += chunk;
      
      // Send text delta to client
      sendMessage(ws, { type: 'text_delta', delta: chunk });
      
      // Check for complete sentences for TTS - start immediately!
      if (wantsAudio) {
        const { sentences, remaining } = extractCompleteSentences(sentenceBuffer);
        
        for (const sentence of sentences) {
          if (sentence.length > 2) { // Skip tiny fragments
            const myIndex = sentenceCount;
            sentenceCount++;
            console.log(`🔊 [${connectionId}] TTS starting sentence ${myIndex + 1}: "${sentence.substring(0, 50)}..."`);
            
            // Start TTS immediately and send as soon as ready
            textToSpeech(sentence).then(audioData => {
              audioResults[myIndex] = audioData;
              trySendAudioChunks();
            }).catch(err => {
              console.error(`⚠️ [${connectionId}] TTS error: ${err.message}`);
              audioResults[myIndex] = null;
              trySendAudioChunks();
            });
          }
        }
        
        sentenceBuffer = remaining;
      }
    }
    
    // Send text_done
    sendMessage(ws, { type: 'text_done' });
    console.log(`🦋 [${connectionId}] Dolores (${Date.now() - startLLM}ms): "${fullResponse.substring(0, 100)}..."`);
    
    // Also send full response for backwards compatibility
    sendMessage(ws, { type: 'response', text: fullResponse });
    
    // Handle remaining text for TTS
    if (wantsAudio && sentenceBuffer.trim().length > 2) {
      const myIndex = sentenceCount;
      sentenceCount++;
      console.log(`🔊 [${connectionId}] TTS starting final: "${sentenceBuffer.substring(0, 50)}..."`);
      
      textToSpeech(sentenceBuffer.trim()).then(audioData => {
        audioResults[myIndex] = audioData;
        trySendAudioChunks();
        // After final chunk, send audio_done
        if (nextAudioToSend >= sentenceCount) {
          sendMessage(ws, { type: 'audio_done' });
          console.log(`🔊 [${connectionId}] Audio streaming complete`);
        }
      }).catch(err => {
        audioResults[myIndex] = null;
        trySendAudioChunks();
      });
    } else if (wantsAudio && sentenceCount > 0) {
      // Wait for pending audio to finish, then send audio_done
      const checkComplete = setInterval(() => {
        trySendAudioChunks();
        if (nextAudioToSend >= sentenceCount) {
          clearInterval(checkComplete);
          sendMessage(ws, { type: 'audio_done' });
          console.log(`🔊 [${connectionId}] Audio streaming complete`);
        }
      }, 100);
    }

  } catch (error) {
    console.error(`❌ [${connectionId}] Streaming error:`, error.message);
    // Fallback to non-streaming
    console.log(`↩️ [${connectionId}] Falling back to non-streaming...`);
    await handleTextMessage(ws, text, connectionId, wantsAudio);
  }
}

/**
 * Handle text message - non-streaming fallback
 */
async function handleTextMessage(ws, text, connectionId, wantsAudio = true) {
  console.log(`📝 [${connectionId}] Jac: "${text}" (audio: ${wantsAudio})`);

  try {
    console.log(`🦋 [${connectionId}] Asking OpenClaw...`);
    const startLLM = Date.now();
    const response = await callOpenClaw(text);
    console.log(`🦋 [${connectionId}] Dolores (${Date.now() - startLLM}ms): "${response}"`);

    sendMessage(ws, { type: 'response', text: response });

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

async function handleAudioMessage(ws, audioBase64, connectionId, useStreaming = true) {
  console.log(`🎙️ [${connectionId}] Received audio (${Math.round(audioBase64.length / 1024)}KB)`);
  
  try {
    console.log(`🎙️ [${connectionId}] Transcribing with Whisper...`);
    const startSTT = Date.now();
    const transcript = await whisperTranscribe(audioBase64);
    console.log(`🎙️ [${connectionId}] Whisper (${Date.now() - startSTT}ms): "${transcript}"`);
    
    if (!transcript || transcript.length === 0) {
      console.log(`⚠️ [${connectionId}] Empty transcript, ignoring`);
      sendMessage(ws, { type: 'transcript', text: '' });
      return;
    }
    
    sendMessage(ws, { type: 'transcript', text: transcript });
    
    // Use streaming if enabled
    if (useStreaming && ENABLE_STREAMING) {
      await handleTextMessageStreaming(ws, transcript, connectionId, true);
    } else {
      await handleTextMessage(ws, transcript, connectionId, true);
    }
    
  } catch (error) {
    console.error(`❌ [${connectionId}] STT Error:`, error.message);
    sendMessage(ws, { type: 'error', error: `Transcriptie mislukt: ${error.message}` });
  }
}

function startServer() {
  const wss = new WebSocketServer({ host: '0.0.0.0', port: PORT });
  let connectionCounter = 0;
  const activeConnections = new Map();

  const ttsProvider = AZURE_SPEECH_KEY ? 'Azure Fenna 🇳🇱' : (ELEVENLABS_API_KEY ? 'ElevenLabs' : 'None');

  console.log(`🚀 Dolores Voice Server starting...`);
  console.log(`🔗 OpenClaw: ${OPENCLAW_URL}`);
  console.log(`🔑 Auth: ✓`);
  console.log(`🎤 TTS: ${ttsProvider}`);
  console.log(`📡 Streaming: ${ENABLE_STREAMING ? 'enabled' : 'disabled'}`);

  const HEARTBEAT_INTERVAL = 30000;
  
  const heartbeatInterval = setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws.isAlive === false) {
        console.log(`💔 Connection timed out, terminating`);
        return ws.terminate();
      }
      ws.isAlive = false;
      ws.ping();
    });
  }, HEARTBEAT_INTERVAL);

  wss.on('close', () => {
    clearInterval(heartbeatInterval);
  });

  wss.on('connection', (ws, request) => {
    const connectionId = ++connectionCounter;
    const clientIP = request.socket.remoteAddress;
    console.log(`🔌 [${connectionId}] Connected from ${clientIP}`);
    
    ws.isAlive = true;
    ws.connectionId = connectionId;
    activeConnections.set(connectionId, { ws, connectedAt: Date.now() });

    ws.on('pong', () => {
      ws.isAlive = true;
    });
    
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
      backend: 'OpenClaw',
      streaming: ENABLE_STREAMING
    });

    ws.on('message', async (data) => {
      ws.isAlive = true;
      try {
        const message = JSON.parse(data.toString());
        const useStreaming = message.streaming !== false && ENABLE_STREAMING;
        
        if (message.type === 'text') {
          const wantsAudio = message.wantsAudio !== false;
          if (useStreaming) {
            await handleTextMessageStreaming(ws, message.text, connectionId, wantsAudio);
          } else {
            await handleTextMessage(ws, message.text, connectionId, wantsAudio);
          }
        } else if (message.type === 'audio') {
          await handleAudioMessage(ws, message.data, connectionId, useStreaming);
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
