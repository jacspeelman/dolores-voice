import WebSocket from 'ws';
import fs from 'fs';
import path from 'path';

const url = process.env.WS_URL || 'ws://127.0.0.1:8765';

function silencePcm(seconds = 1, sampleRate = 16000) {
  const samples = Math.floor(seconds * sampleRate);
  // 16-bit LE mono => 2 bytes per sample
  return Buffer.alloc(samples * 2);
}

function writeWav16Mono(outPath, pcm, sampleRate = 16000) {
  // Minimal WAV header for PCM S16LE mono
  const numChannels = 1;
  const bitsPerSample = 16;
  const byteRate = sampleRate * numChannels * bitsPerSample / 8;
  const blockAlign = numChannels * bitsPerSample / 8;
  const dataSize = pcm.length;

  const header = Buffer.alloc(44);
  header.write('RIFF', 0);
  header.writeUInt32LE(36 + dataSize, 4);
  header.write('WAVE', 8);
  header.write('fmt ', 12);
  header.writeUInt32LE(16, 16); // PCM fmt chunk size
  header.writeUInt16LE(1, 20);  // audio format = PCM
  header.writeUInt16LE(numChannels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(blockAlign, 32);
  header.writeUInt16LE(bitsPerSample, 34);
  header.write('data', 36);
  header.writeUInt32LE(dataSize, 40);

  fs.writeFileSync(outPath, Buffer.concat([header, pcm]));
}

const ws = new WebSocket(url);
let outPcmChunks = [];
let gotAudio = 0;

ws.on('open', () => {
  console.log('open', url);
  // Send a couple of silence chunks to trigger STT pipeline (server-side).
  // NOTE: If server ignores silence, speak into a real client; this script is mainly for verifying audio protocol.
  const pcm = silencePcm(0.5);
  ws.send(JSON.stringify({ type: 'audio', data: pcm.toString('base64') }));
  setTimeout(() => {
    ws.send(JSON.stringify({ type: 'audio', data: pcm.toString('base64') }));
  }, 200);
});

ws.on('message', (data) => {
  const text = data.toString();
  let msg;
  try { msg = JSON.parse(text); } catch { return; }

  if (msg.type === 'audio') {
    const { format, sampleRate, channels } = msg;
    if (format !== 'pcm_s16le' || sampleRate !== 16000 || channels !== 1) {
      console.log('audio: unexpected format', { format, sampleRate, channels, bytes: (msg.data?.length || 0) });
      return;
    }

    const pcm = Buffer.from(msg.data, 'base64');
    outPcmChunks.push(pcm);
    gotAudio++;
    console.log(`audio chunk #${msg.index ?? '?'}: ${pcm.length} bytes`);
  } else if (msg.type === 'audio_end') {
    console.log('audio_end');
    const pcm = Buffer.concat(outPcmChunks);
    const outDir = process.env.OUT_DIR || process.cwd();
    const outPath = path.join(outDir, `tts-${Date.now()}.wav`);
    writeWav16Mono(outPath, pcm, 16000);
    console.log(`wrote ${outPath} (${pcm.length} bytes PCM, ${gotAudio} chunks)`);
    ws.close();
  } else if (msg.type === 'state') {
    console.log('state', msg.state);
  } else if (msg.type === 'transcript') {
    console.log('transcript', msg.text);
  } else if (msg.type === 'error') {
    console.log('error', msg.error);
  }
});

ws.on('close', (code, reason) => {
  console.log('close', code, reason?.toString());
  process.exit(0);
});

ws.on('error', (err) => {
  console.error('error', err);
});
