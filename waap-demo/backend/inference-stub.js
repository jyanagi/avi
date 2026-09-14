'use strict';
/*
 * ACME Frontier Model Gateway - inference stub.
 * Zero npm dependencies. Node 18+.
 *
 * Speaks the OpenAI chat-completions wire protocol including SSE token
 * streaming, so at the Avi enforcement point it is indistinguishable from
 * vLLM, NIM or a hosted frontier endpoint. No model, no GPU. The response
 * text is templated; the protocol is real.
 */

const http = require('http');
const https = require('https');
const fs = require('fs');
const crypto = require('crypto');

const PORT = parseInt(process.env.LLM_PORT || '9443', 10);
const NODE_NAME = process.env.LLM_NODE_NAME || 'mcp-a-01a';
const TLS_CERT = process.env.LLM_TLS_CERT || '';
const TLS_KEY = process.env.LLM_TLS_KEY || '';
const MS_PER_TOKEN = parseInt(process.env.LLM_MS_PER_TOKEN || '18', 10);

const MODELS = [
  { id: 'acme-frontier-70b', owned_by: 'acme-ai-platform', context_window: 131072 },
  { id: 'acme-frontier-8b', owned_by: 'acme-ai-platform', context_window: 32768 },
  { id: 'acme-embed-v2', owned_by: 'acme-ai-platform', context_window: 8192 }
];

const CANNED = [
  'Based on the current inventory position, SKU-4411 is fully reserved with 96 units on hand and none available to promise. The next inbound receipt is scheduled against PO-3341 at the DFW-3 site.',
  'Three vendors currently supply this component. Northgate Precision carries the strongest on-time record at 97.4 percent, while Halcyon Components remains on probation following Q1 delivery misses.',
  'I have summarised the open payable position. Two invoices are approved and one is held pending a quality escalation. I can list them if you would like the detail.',
  'The shipment is currently in transit to CLT-2. Rerouting is possible but would add roughly two days to the delivery estimate and incur a reconsignment fee.'
];

function tokenize(text) {
  return text.match(/\S+\s*/g) || [];
}

function estimateTokens(messages) {
  const s = JSON.stringify(messages || []);
  return Math.max(1, Math.ceil(s.length / 4));
}

function pickReply(messages) {
  const last = (messages || []).filter((m) => m.role === 'user').pop();
  const seed = last ? last.content || '' : '';
  let h = 0;
  for (let i = 0; i < String(seed).length; i++) h = (h * 31 + String(seed).charCodeAt(i)) >>> 0;
  return CANNED[h % CANNED.length];
}

function send(res, status, obj) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(status, {
    'content-type': 'application/json',
    'content-length': body.length,
    'x-served-by': NODE_NAME
  });
  res.end(body);
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(Object.assign(new Error('payload too large'), { code: 413 }));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

async function streamCompletion(res, model, reply, promptTokens) {
  const id = 'chatcmpl-' + crypto.randomBytes(10).toString('hex');
  const created = Math.floor(Date.now() / 1000);
  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-store',
    connection: 'keep-alive',
    'x-served-by': NODE_NAME
  });

  const frame = (delta, finish) => 'data: ' + JSON.stringify({
    id, object: 'chat.completion.chunk', created, model,
    choices: [{ index: 0, delta, finish_reason: finish || null }]
  }) + '\n\n';

  res.write(frame({ role: 'assistant', content: '' }));

  const toks = tokenize(reply);
  let i = 0;
  await new Promise((resolve) => {
    const t = setInterval(() => {
      if (i >= toks.length || res.writableEnded) {
        clearInterval(t);
        return resolve();
      }
      res.write(frame({ content: toks[i++] }));
    }, MS_PER_TOKEN);
  });

  res.write(frame({}, 'stop'));
  res.write('data: ' + JSON.stringify({
    id, object: 'chat.completion.chunk', created, model, choices: [],
    usage: {
      prompt_tokens: promptTokens,
      completion_tokens: toks.length,
      total_tokens: promptTokens + toks.length
    }
  }) + '\n\n');
  res.write('data: [DONE]\n\n');
  res.end();
}

async function handler(req, res) {
  const url = new URL(req.url, 'http://localhost');

  if (url.pathname === '/healthz') {
    return send(res, 200, { status: 'ok', node: NODE_NAME });
  }

  if (url.pathname === '/v1/models' && req.method === 'GET') {
    return send(res, 200, {
      object: 'list',
      data: MODELS.map((m) => ({
        id: m.id, object: 'model', created: 1767225600,
        owned_by: m.owned_by, context_window: m.context_window
      }))
    });
  }

  if (url.pathname === '/v1/embeddings' && req.method === 'POST') {
    let body;
    try {
      body = JSON.parse(await readBody(req, 4 * 1024 * 1024));
    } catch (e) {
      return send(res, 400, { error: { message: 'invalid request body', type: 'invalid_request_error' } });
    }
    const inputs = Array.isArray(body.input) ? body.input : [body.input || ''];
    return send(res, 200, {
      object: 'list',
      model: body.model || 'acme-embed-v2',
      data: inputs.map((text, index) => {
        const seed = crypto.createHash('sha256').update(String(text)).digest();
        const embedding = Array.from({ length: 32 }, (_, k) => (seed[k % 32] / 128) - 1);
        return { object: 'embedding', index, embedding };
      }),
      usage: { prompt_tokens: estimateTokens(inputs), total_tokens: estimateTokens(inputs) }
    });
  }

  if (url.pathname === '/v1/chat/completions' && req.method === 'POST') {
    let raw;
    try {
      raw = await readBody(req, 8 * 1024 * 1024);
    } catch (err) {
      return send(res, err.code === 413 ? 413 : 400, {
        error: { message: 'request body too large', type: 'invalid_request_error' }
      });
    }
    let body;
    try {
      body = JSON.parse(raw);
    } catch (e) {
      return send(res, 400, { error: { message: 'invalid JSON', type: 'invalid_request_error' } });
    }

    const model = body.model || 'acme-frontier-70b';
    if (!MODELS.some((m) => m.id === model)) {
      return send(res, 404, {
        error: { message: 'model not found: ' + model, type: 'invalid_request_error' }
      });
    }

    const promptTokens = estimateTokens(body.messages);
    const reply = pickReply(body.messages);

    // NOTE: streaming (SSE) is intentionally disabled for this path. A streamed
    // upstream response races with the WAF's request-phase block at the Avi
    // enforcement point, producing intermittent 503 / connection-reset instead
    // of a clean 403 on blocked requests. A single buffered response with no
    // artificial delay makes WAF blocking deterministic. Set FORCE_STREAM=1 to
    // restore SSE if you specifically want to demonstrate streaming.
    if (body.stream && process.env.FORCE_STREAM === '1') {
      return streamCompletion(res, model, reply, promptTokens);
    }

    const completionTokens = tokenize(reply).length;
    return send(res, 200, {
      id: 'chatcmpl-' + crypto.randomBytes(10).toString('hex'),
      object: 'chat.completion',
      created: Math.floor(Date.now() / 1000),
      model,
      choices: [{ index: 0, message: { role: 'assistant', content: reply }, finish_reason: 'stop' }],
      usage: {
        prompt_tokens: promptTokens,
        completion_tokens: completionTokens,
        total_tokens: promptTokens + completionTokens
      }
    });
  }

  return send(res, 404, { error: { message: 'unknown endpoint', type: 'invalid_request_error' } });
}

const useTls = TLS_CERT && TLS_KEY && fs.existsSync(TLS_CERT) && fs.existsSync(TLS_KEY);
const server = useTls
  ? https.createServer({ cert: fs.readFileSync(TLS_CERT), key: fs.readFileSync(TLS_KEY) }, handler)
  : http.createServer(handler);

server.listen(PORT, () => {
  console.log('[llm] %s listening on %s://0.0.0.0:%d', NODE_NAME, useTls ? 'https' : 'http', PORT);
  console.log('[llm] endpoints: /v1/models /v1/chat/completions /v1/embeddings');
});
