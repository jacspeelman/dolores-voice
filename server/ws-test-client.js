import WebSocket from 'ws';

const url = process.env.WS_URL || 'ws://127.0.0.1:8765';

function silencePcm(seconds = 1, sampleRate = 16000) {
  const samples = Math.floor(seconds * sampleRate);
  // 16-bit LE mono => 2 bytes per sample
  return Buffer.alloc(samples * 2);
}

const ws = new WebSocket(url);

ws.on('open', () => {
  console.log('open');
  const pcm = silencePcm(1);
  ws.send(JSON.stringify({ type: 'audio', data: pcm.toString('base64') }));
  setTimeout(() => {
    ws.send(JSON.stringify({ type: 'audio', data: pcm.toString('base64') }));
  }, 200);
});

ws.on('message', (data) => {
  console.log('msg', data.toString().slice(0, 200));
});

ws.on('close', (code, reason) => {
  console.log('close', code, reason?.toString());
  process.exit(0);
});

ws.on('error', (err) => {
  console.error('error', err);
});
