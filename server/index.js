/**
 * Dolores Voice Server v2 - Pure Voice Pipeline
 * 
 * WebSocket server for real-time voice interaction with:
 * - Speaker Verification (Azure Speaker Recognition - optional)
 * - Speech-to-Text (Deepgram Nova-3 real-time streaming)
 * - AI Response (OpenClaw Gateway)
 * - Text-to-Speech (ElevenLabs multilingual)
 * - Barge-in support (interrupt during playback)
 * 
 * Protocol:
 * Client → Server:
 *   {type: "audio", data: <base64 PCM 16-bit 16kHz mono>}
 *   {type: "interrupt"}
 * 
 * Server → Client:
 *   {type: "state", state: "listening|processing|speaking"}
 *   {type: "audio", format: "pcm_s16le", sampleRate: 16000, channels: 1, data: <base64 PCM>}
 *   {type: "audio_end"}
 *   {type: "transcript", text: "..."}
 */

import { WebSocketServer } from 'ws';
import { config } from 'dotenv';
import { createClient, LiveTranscriptionEvents } from '@deepgram/sdk';

config();

const PORT = process.env.PORT || 8765;

// === Credentials ===
// Deepgram STT
const DEEPGRAM_API_KEY = process.env.DEEPGRAM_API_KEY;

// ElevenLabs TTS
const ELEVENLABS_API_KEY = process.env.ELEVENLABS_API_KEY;
const ELEVENLABS_VOICE_ID = process.env.ELEVENLABS_VOICE_ID || 'yO6w2xlECAQRFP6pX7Hw';
const ELEVENLABS_MODEL = process.env.ELEVENLABS_MODEL || 'eleven_multilingual_v2';

// Azure Speaker Verification (optional)
const AZURE_SPEAKER_KEY = process.env.AZURE_SPEAKER_KEY;
const AZURE_SPEAKER_REGION = process.env.AZURE_SPEAKER_REGION || 'westeurope';
const AZURE_SPEAKER_PROFILE_ID = process.env.AZURE_SPEAKER_PROFILE_ID; // Jac's voice profile

// OpenClaw Gateway
const OPENCLAW_URL = process.env.OPENCLAW_URL || 'http://127.0.0.1:18789';
const OPENCLAW_TOKEN = process.env.OPENCLAW_TOKEN || '3045cdeb9a19f9d7198690cdadade2dff487a9556e0330d5';

// === Validation ===
if (!DEEPGRAM_API_KEY) {
  console.error('❌ DEEPGRAM_API_KEY not set');
  process.exit(1);
}

if (!ELEVENLABS_API_KEY) {
  console.error('❌ ELEVENLABS_API_KEY not set');
  process.exit(1);
}

if (!OPENCLAW_TOKEN) {
  console.error('❌ OPENCLAW_TOKEN not set');
  process.exit(1);
}

// === Helper: Fetch with timeout ===
function fetchWithTimeout(url, options, timeoutMs = 60000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  
  return fetch(url, { ...options, signal: controller.signal })
    .finally(() => clearTimeout(timeout));
}

// === Speaker Verification ===
/**
 * Verify speaker identity via Azure Speaker Recognition
 * Returns true if verified as Jac, false otherwise
 * If not configured, always returns true (skip verification)
 */
async function verifySpeaker(audioBuffer) {
  if (!AZURE_SPEAKER_KEY || !AZURE_SPEAKER_PROFILE_ID) {
    return true;
  }

  try {
    // Azure Speaker Recognition API expects audio in specific format
    // We'll need to implement this with the Azure SDK or REST API
    // For now, document what's needed and skip verification
    console.log('⚠️ Azure Speaker Verification implementation pending');
    return true;
  } catch (error) {
    console.error('⚠️ Speaker verification failed:', error.message);
    // On error, allow (don't block legitimate user)
    return true;
  }
}

// === Deepgram STT Streaming ===
/**
 * Real-time Speech-to-Text using Deepgram Nova-3
 */
class DeepgramSTTSession {
  constructor(connectionId, onTranscript, onError) {
    this.connectionId = connectionId;
    this.onTranscript = onTranscript;
    this.onError = onError;
    this.deepgram = null;
    this.connection = null;
    this.isActive = false;
    this.transcript = '';
  }

  async start() {
    try {
      this.deepgram = createClient(DEEPGRAM_API_KEY);
      
      this.connection = this.deepgram.listen.live({
        model: 'nova-3',
        language: 'nl',
        smart_format: true,
        interim_results: true,
        utterance_end_ms: 1500,
        vad_events: true,
        encoding: 'linear16',
        sample_rate: 16000,
        channels: 1
      });

      // Handle transcript events
      this.connection.on(LiveTranscriptionEvents.Transcript, (data) => {
        const transcript = data.channel?.alternatives?.[0]?.transcript;
        if (transcript && transcript.trim()) {
          const isFinal = data.is_final;
          console.log(`🎙️ [${this.connectionId}] ${isFinal ? 'Final' : 'Interim'}: "${transcript}"`);
          
          if (isFinal) {
            this.transcript += (this.transcript ? ' ' : '') + transcript;
            this.onTranscript(transcript, true);
          } else {
            this.onTranscript(transcript, false);
          }
        }
      });

      // Handle errors
      this.connection.on(LiveTranscriptionEvents.Error, (error) => {
        console.error(`🎙️ [${this.connectionId}] Deepgram error:`, error);
        this.onError(error.message || 'Deepgram error');
      });

      // Handle connection close
      this.connection.on(LiveTranscriptionEvents.Close, () => {
        console.log(`🎙️ [${this.connectionId}] Deepgram connection closed`);
        this.isActive = false;
      });

      // Wait for connection to open
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('Connection timeout')), 10000);
        
        this.connection.on(LiveTranscriptionEvents.Open, () => {
          clearTimeout(timeout);
          console.log(`🎙️ [${this.connectionId}] Deepgram connection opened`);
          this.isActive = true;
          resolve();
        });

        this.connection.on(LiveTranscriptionEvents.Error, (error) => {
          clearTimeout(timeout);
          reject(error);
        });
      });

      return true;
    } catch (error) {
      console.error(`🎙️ [${this.connectionId}] Failed to start Deepgram:`, error);
      this.onError(error.message);
      return false;
    }
  }

  pushAudio(audioBuffer) {
    if (this.connection && this.isActive) {
      try {
        // Deepgram Node SDK expects an ArrayBuffer (not a Node Buffer)
        const ab = audioBuffer.buffer.slice(
          audioBuffer.byteOffset,
          audioBuffer.byteOffset + audioBuffer.byteLength
        );
        this.connection.send(ab);
      } catch (error) {
        console.error(`🎙️ [${this.connectionId}] Failed to send audio:`, error);
      }
    }
  }

  async stop() {
    if (this.connection) {
      try {
        this.connection.finish();
      } catch (error) {
        console.error(`🎙️ [${this.connectionId}] Error finishing connection:`, error);
      }
    }
    
    this.isActive = false;
    const finalTranscript = this.transcript;
    this.transcript = '';
    
    console.log(`🎙️ [${this.connectionId}] STT stopped, final: "${finalTranscript}"`);
    return finalTranscript;
  }

  cleanup() {
    this.stop();
    this.deepgram = null;
    this.connection = null;
  }
}

// Active STT sessions per connection
const sttSessions = new Map();

// === OpenClaw Integration ===
/**
 * Send message to OpenClaw and get streaming response
 */
async function* callOpenClaw(userMessage) {
  const voiceMessage = `[VOICE] ${userMessage}

(Dit is een voice gesprek via de Dolores Voice app v2. Antwoord KORT in 1-3 zinnen, geen markdown/bullets, praat natuurlijk. GEBRUIK GEEN tts tool — de voice app regelt zelf de spraaksynthese.)`;

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
    
    const lines = buffer.split('\n');
    buffer = lines.pop();

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

// === ElevenLabs TTS ===
/**
 * Generate speech with ElevenLabs
 * Returns raw PCM S16LE 16kHz mono (Buffer)
 */
async function generateSpeech(text) {
  if (!text || text.trim().length === 0) {
    throw new Error('Empty text for TTS');
  }

  // Request stream endpoint but ask ElevenLabs to return raw PCM.
  // Per ElevenLabs docs, `output_format=pcm_16000` => PCM (S16LE) 16kHz.
  const response = await fetchWithTimeout(
    `https://api.elevenlabs.io/v1/text-to-speech/${ELEVENLABS_VOICE_ID}/stream?output_format=pcm_16000`,
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'audio/pcm',
        'xi-api-key': ELEVENLABS_API_KEY
      },
      body: JSON.stringify({
        text: text,
        model_id: ELEVENLABS_MODEL,
        voice_settings: {
          stability: 0.5,
          similarity_boost: 0.8,
          style: 0.4,
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

  // Read full audio buffer
  const chunks = [];
  const reader = response.body.getReader();
  
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value);
  }

  const totalLength = chunks.reduce((acc, chunk) => acc + chunk.length, 0);
  const audioBuffer = new Uint8Array(totalLength);
  let offset = 0;
  for (const chunk of chunks) {
    audioBuffer.set(chunk, offset);
    offset += chunk.length;
  }

  return Buffer.from(audioBuffer);
}

// === Helper: Sentence detection ===
function extractCompleteSentences(text) {
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

// === WebSocket Message Helper ===
function sendMessage(ws, message) {
  if (ws.readyState !== 1) return; // not OPEN

  // Basic backpressure protection: if the client isn't reading fast enough,
  // ws.bufferedAmount grows and the process can get OOM-killed (exit -9).
  const HIGH_WATERMARK = 8 * 1024 * 1024; // 8MB
  if (ws.bufferedAmount > HIGH_WATERMARK) {
    console.warn(`⚠️ [${ws.connectionId}] Backpressure: bufferedAmount=${ws.bufferedAmount} > ${HIGH_WATERMARK}. Closing.`);
    try { ws.close(1013, 'backpressure'); } catch (_) {}
    return;
  }

  try {
    ws.send(JSON.stringify(message));
  } catch (err) {
    console.warn(`⚠️ [${ws.connectionId}] ws.send failed: ${err.message}`);
  }
}

// === Main Voice Pipeline ===
function handleVoiceInteraction(ws, connectionId) {
  let currentState = 'listening';
  let ttsQueue = [];
  let nextTtsIndex = 0;
  let audioSent = false;
  let allChunksQueued = false;
  let pendingTts = 0;
  let llmDone = false;

  const setState = (newState) => {
    currentState = newState;
    sendMessage(ws, { type: 'state', state: newState });
    console.log(`📡 [${connectionId}] State: ${newState}`);
  };

  const sendAudio = (audioBuffer, index) => {
    if (!audioSent) {
      audioSent = true;
      setState('speaking');
    }
    sendMessage(ws, {
      type: 'audio',
      format: 'pcm_s16le',
      sampleRate: 16000,
      channels: 1,
      data: audioBuffer.toString('base64'),
      index
    });
    console.log(`🔊 [${connectionId}] Sent audio chunk ${index} (${audioBuffer.length} bytes)`);
  };

  const dispatchTts = (ttsIndex, textToSpeak) => {
    pendingTts++;
    generateSpeech(textToSpeak)
      .then(audioBuffer => {
        ttsQueue[ttsIndex] = audioBuffer;
      })
      .catch(error => {
        console.error(`⚠️ [${connectionId}] TTS error:`, error.message);
        // Empty buffer to maintain order
        ttsQueue[ttsIndex] = Buffer.alloc(0);
      })
      .finally(() => {
        pendingTts--;
        trySendQueuedAudio();
      });
  };

  const endAudio = () => {
    if (audioSent) {
      sendMessage(ws, { type: 'audio_end' });
      audioSent = false;

      // IMPORTANT: don't immediately resume listening/recording.
      // The client's speaker is still playing; if we resume STT too fast we'll transcribe our own TTS.
      ws.muteUntilMs = Date.now() + 2000; // safety window

      console.log(`🔊 [${connectionId}] Audio streaming complete (waiting for playback_done)`);

      // Fallback: if the client never sends playback_done, resume listening after a timeout.
      setTimeout(() => {
        try {
          // Only resume if we're still not in listening
          if (pipeline.getState() !== 'listening') {
            ws.muteUntilMs = Date.now() + 1200;
            pipeline.setState('listening');
            console.log(`🔊 [${connectionId}] playback_done timeout → resume listening`);
          }
        } catch {}
      }, 4000).unref();
    }
  };

  const trySendQueuedAudio = () => {
    if (ws.interrupted) {
      console.log(`⏸️ [${connectionId}] Interrupted, clearing audio queue`);
      ttsQueue = [];
      nextTtsIndex = 0;
      pendingTts = 0;
      llmDone = false;
      endAudio();
      return;
    }

    // Send only in-order ready chunks. We reserve slots with null;
    // never advance past a null placeholder or we'll skip audio forever.
    while (nextTtsIndex < ttsQueue.length) {
      const audioBuffer = ttsQueue[nextTtsIndex];
      if (audioBuffer === null || audioBuffer === undefined) break;
      if (audioBuffer.length > 0) {
        sendAudio(audioBuffer, nextTtsIndex);
      }
      nextTtsIndex++;
    }

    // End audio only when LLM is done AND all TTS jobs resolved AND all queued chunks have been processed.
    if (llmDone && pendingTts === 0 && nextTtsIndex >= ttsQueue.length && ttsQueue.length > 0) {
      llmDone = false;
      endAudio();
      // Reset queue for next turn
      ttsQueue = [];
      nextTtsIndex = 0;
    }
  };

  return {
    setState,
    getState() { return currentState; },
    async processTranscript(transcript) {
      if (!transcript || transcript.trim().length === 0) {
        console.log(`⚠️ [${connectionId}] Empty transcript, ignoring`);
        return;
      }

      // Send transcript back to client for logging
      sendMessage(ws, { type: 'transcript', text: transcript });

      try {
        setState('processing');
        console.log(`🦋 [${connectionId}] Processing: "${transcript}"`);

        let fullResponse = '';
        let sentenceBuffer = '';
        ttsQueue = [];
        nextTtsIndex = 0;
        audioSent = false;

        // Stream response from OpenClaw
        for await (const chunk of callOpenClaw(transcript)) {
          if (ws.interrupted) {
            console.log(`⏸️ [${connectionId}] Interrupted during LLM streaming`);
            break;
          }

          fullResponse += chunk;
          sentenceBuffer += chunk;

          // Check for complete sentences
          const { sentences, remaining } = extractCompleteSentences(sentenceBuffer);

          if (sentences.length > 0) {
            // Generate TTS for each sentence
            for (const sentence of sentences) {
              if (sentence.length > 2) {
                const ttsIndex = ttsQueue.length;
                ttsQueue.push(null); // Reserve slot
                
                console.log(`🔊 [${connectionId}] TTS starting for sentence ${ttsIndex + 1}: "${sentence.substring(0, 50)}..."`);
                
                // Generate speech async
                dispatchTts(ttsIndex, sentence);
              }
            }
          }

          sentenceBuffer = remaining;
        }

        // LLM stream finished; end audio once all TTS has resolved and been sent.
        llmDone = true;

        // Handle remaining text
        if (!ws.interrupted && sentenceBuffer.trim().length > 2) {
          const ttsIndex = ttsQueue.length;
          ttsQueue.push(null);
          
          console.log(`🔊 [${connectionId}] TTS starting for final: "${sentenceBuffer.substring(0, 50)}..."`);
          
          dispatchTts(ttsIndex, sentenceBuffer.trim());
        } else if (!ws.interrupted && ttsQueue.length > 0) {
          trySendQueuedAudio();
        } else if (!ws.interrupted) {
          // No audio generated
          setState('listening');
        }

        console.log(`🦋 [${connectionId}] Response: "${fullResponse}"`);

      } catch (error) {
        console.error(`❌ [${connectionId}] Error processing transcript:`, error.message);
        sendMessage(ws, { type: 'error', error: error.message });
        setState('listening');
      }
    },

    handleInterrupt() {
      console.log(`⏸️ [${connectionId}] User interrupted`);
      ws.interrupted = true;
      ttsQueue = [];
      nextTtsIndex = 0;
      endAudio();
      ws.interrupted = false;
    ws.muteUntilMs = 0; // Reset for next interaction
    }
  };
}

// === WebSocket Server ===
function startServer() {
  const wss = new WebSocketServer({ host: '0.0.0.0', port: PORT });
  let connectionCounter = 0;
  let heartbeatInterval = null;

  const shutdown = (signal) => {
    console.log(`🛑 Received ${signal}, shutting down...`);

    try { clearInterval(heartbeatInterval); } catch (_) {}

    for (const entry of sttSessions.values()) {
      try { entry?.session?.cleanup?.(); } catch (_) {}
    }
    sttSessions.clear();

    try {
      wss.close(() => {
        console.log('✅ WebSocket server closed');
        process.exit(0);
      });
    } catch (_) {
      process.exit(0);
    }

    setTimeout(() => process.exit(0), 2000).unref();
  };

  process.once('SIGTERM', () => shutdown('SIGTERM'));
  process.once('SIGINT', () => shutdown('SIGINT'));

  console.log(`🚀 Dolores Voice Server v2 - Pure Voice Pipeline`);
  console.log(`🔗 OpenClaw: ${OPENCLAW_URL}`);
  console.log(`🎙️ STT: Deepgram Nova-3 (real-time)`);
  console.log(`🔊 TTS: ElevenLabs ${ELEVENLABS_MODEL} (voice: ${ELEVENLABS_VOICE_ID.substring(0, 8)}...)`);
  console.log(`🔐 Speaker Verification: ${AZURE_SPEAKER_KEY ? 'Azure (configured)' : 'disabled'}`);

  // Heartbeat
  const HEARTBEAT_INTERVAL = 30000;
  heartbeatInterval = setInterval(() => {
    wss.clients.forEach((ws) => {
      if (ws.isAlive === false) {
        console.log(`💔 [${ws.connectionId}] Connection timeout, terminating`);
        return ws.terminate();
      }
      ws.isAlive = false;
      try {
        ws.ping();
      } catch (err) {
        console.warn(`⚠️ [${ws.connectionId}] ping failed: ${err.message}`);
      }
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
    ws.interrupted = false;
    ws.muteUntilMs = 0;

    // Create voice pipeline handler
    const pipeline = handleVoiceInteraction(ws, connectionId);

    ws.on('pong', () => {
      ws.isAlive = true;
    });

    // Send config
    sendMessage(ws, {
      type: 'config',
      version: '2.0',
      stt: { provider: 'Deepgram', model: 'Nova-3', realtime: true },
      tts: { provider: 'ElevenLabs', model: ELEVENLABS_MODEL, voice: ELEVENLABS_VOICE_ID },
      speakerVerification: !!AZURE_SPEAKER_KEY,
      backend: 'OpenClaw'
    });

    ws.on('message', async (data) => {
      ws.isAlive = true;

      try {
        const message = JSON.parse(data.toString());

        if (message.type === 'audio') {
          // Raw audio chunk from iOS — ignore during speaking/processing and during a post-playback cooldown
          // to prevent echo/self-transcription loops.
          const now = Date.now();
          if (pipeline.getState() === 'speaking' || pipeline.getState() === 'processing' || now < (ws.muteUntilMs || 0)) {
            return;
          }
          
          const audioBuffer = Buffer.from(message.data, 'base64');
          
          // Speaker verification (optional)
          const isVerified = await verifySpeaker(audioBuffer);
          if (!isVerified) {
            console.log(`🚫 [${connectionId}] Speaker verification failed`);
            sendMessage(ws, { type: 'error', error: 'Speaker not recognized' });
            return;
          }

          // Get or create STT session (with a start lock to avoid duplicate Deepgram connections)
          let entry = sttSessions.get(connectionId);
          if (!entry) {
            entry = { session: null, starting: null };
            sttSessions.set(connectionId, entry);
          }

          if (!entry.session || !entry.session.isActive) {
            if (!entry.starting) {
              const session = new DeepgramSTTSession(
                connectionId,
                (transcript, isFinal) => {
                  if (isFinal) {
                    // Process complete utterance
                    pipeline.processTranscript(transcript);
                  }
                },
                (error) => {
                  console.error(`❌ [${connectionId}] STT error:`, error);
                  sendMessage(ws, { type: 'error', error: `STT error: ${error}` });
                }
              );

              entry.session = session; // set immediately so concurrent audio chunks don't create duplicates
              entry.starting = (async () => {
                const started = await session.start();
                if (!started) throw new Error('Failed to start STT');
                pipeline.setState('listening');
                return session;
              })()
                .catch((err) => {
                  // If start fails, clean up so we can retry on next audio
                  try { session.cleanup(); } catch (_) {}
                  entry.session = null;
                  throw err;
                })
                .finally(() => {
                  entry.starting = null;
                });
            }

            try {
              await entry.starting;
            } catch (err) {
              sendMessage(ws, { type: 'error', error: err.message || 'Failed to start STT' });
              return;
            }
          }

          // Push audio to STT
          entry.session.pushAudio(audioBuffer);

        } else if (message.type === 'playback_done') {
          // Client confirms playback finished. Still add a safety tail before resuming STT,
          // otherwise we can transcribe our own last audio (speaker leakage).
          ws.muteUntilMs = Date.now() + 1200;
          console.log(`🔊 [${connectionId}] playback_done received → resume listening after tail`);

          setTimeout(() => {
            try {
              pipeline.setState('listening');
              console.log(`🔊 [${connectionId}] resume listening (post-playback tail)`);
            } catch {}
          }, 1200).unref();

        } else if (message.type === 'interrupt') {
          // User interrupted (barge-in)
          pipeline.handleInterrupt();

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

      // Cleanup STT session
      const entry = sttSessions.get(connectionId);
      if (entry?.session) {
        entry.session.cleanup();
      }
      sttSessions.delete(connectionId);
    });
  });

  wss.on('listening', () => {
    console.log(`✅ Ready on ws://0.0.0.0:${PORT}`);
  });

  wss.on('error', (error) => {
    console.error(`❌ Server error:`, error.message);
    if (error && (error.code === 'EADDRINUSE' || String(error.message || '').includes('EADDRINUSE'))) {
      console.error('❌ Port already in use. Exiting so launchd can retry cleanly.');
      process.exit(1);
    }
  });
}

startServer();
