import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { EventEmitter } from 'node:events';
import { performance } from 'node:perf_hooks';

import { createRequestEnvelope } from '../src/contracts.mjs';
import { preparePrompt } from '../src/prompt.mjs';
import { boundedHttpRequest, OllamaTransport } from '../src/transport.mjs';
import {
  FIXED_NOW_MS,
  fixtureBytes,
  fixtureHexBytes,
  fixtureJson,
  makeRequest,
  runtime,
} from './helpers.mjs';

async function withServer(handler, action) {
  const server = http.createServer(handler);
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  try {
    return await action(`http://127.0.0.1:${address.port}`);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}

function transportConfig(baseUrl, changes = {}) {
  return {
    ...runtime.config,
    ollama_base_url: baseUrl,
    ...changes,
  };
}

function transportInput(sequence = 1, deadlineMonotonicMs = 30000) {
  const request = createRequestEnvelope(makeRequest(sequence), {
    config: runtime.config,
    nowMs: FIXED_NOW_MS,
  });
  return {
    request,
    prompt: preparePrompt(request, runtime.context, runtime.config),
    signal: new AbortController().signal,
    deadlineMonotonicMs,
  };
}

test('raw response accepts exact byte limit and rejects declared limit plus one', async (t) => {
  await t.test('exact limit', async () => {
    const body = Buffer.alloc(64, 0x61);
    await withServer((request, response) => {
      response.writeHead(200, { 'Content-Length': body.length });
      response.end(body);
    }, async (baseUrl) => {
      const result = await boundedHttpRequest({
        url: baseUrl,
        method: 'GET',
        connectTimeoutMs: 200,
        responseTimeoutMs: 200,
        maxResponseBytes: 64,
      });
      assert.equal(result.body.length, 64);
    });
  });

  await t.test('declared over limit', async () => {
    await withServer((request, response) => {
      response.writeHead(200, { 'Content-Length': 65 });
      response.end(Buffer.alloc(65, 0x61));
    }, async (baseUrl) => {
      await assert.rejects(
        boundedHttpRequest({
          url: baseUrl,
          method: 'GET',
          connectTimeoutMs: 200,
          responseTimeoutMs: 200,
          maxResponseBytes: 64,
        }),
        (error) => error.code === 'raw_response_too_large',
      );
    });
  });
});

test('chunked response aborts at byte limit plus one', async () => {
  await withServer((request, response) => {
    response.writeHead(200, { 'Transfer-Encoding': 'chunked' });
    response.write(Buffer.alloc(32, 0x61));
    response.write(Buffer.alloc(33, 0x62));
    response.end();
  }, async (baseUrl) => {
    await assert.rejects(
      boundedHttpRequest({
        url: baseUrl,
        method: 'GET',
        connectTimeoutMs: 200,
        responseTimeoutMs: 200,
        maxResponseBytes: 64,
      }),
      (error) => error.code === 'raw_response_too_large',
    );
  });
});

test('response deadline is finite and aborts a silent loopback peer', async () => {
  await withServer(() => {}, async (baseUrl) => {
    const started = Date.now();
    await assert.rejects(
      boundedHttpRequest({
        url: baseUrl,
        method: 'GET',
        connectTimeoutMs: 100,
        responseTimeoutMs: 40,
        maxResponseBytes: 1024,
      }),
      (error) => error.code === 'response_deadline',
    );
    assert.ok(Date.now() - started < 1000);
  });
});

test('connect deadline is deterministic and finite with a never-connected socket fixture', async () => {
  const hangingRequest = () => {
    const request = new EventEmitter();
    const socket = new EventEmitter();
    socket.connecting = true;
    socket.destroy = () => {};
    request.write = () => true;
    request.end = () => queueMicrotask(() => request.emit('socket', socket));
    request.destroy = () => {};
    return request;
  };
  const started = Date.now();
  await assert.rejects(
    boundedHttpRequest({
      url: 'http://127.0.0.1:1',
      method: 'GET',
      connectTimeoutMs: 25,
      responseTimeoutMs: 100,
      maxResponseBytes: 1024,
      requestFunction: hangingRequest,
    }),
    (error) => error.code === 'connect_deadline',
  );
  assert.ok(Date.now() - started < 500);
});

test('transport does not send when request construction consumes the monotonic lifetime', async () => {
  let monotonicNow = 0;
  let writeCalled = false;
  let endCalled = false;
  const stalledRequest = () => {
    monotonicNow = 10;
    const request = new EventEmitter();
    request.write = () => { writeCalled = true; };
    request.end = () => { endCalled = true; };
    request.destroy = () => {};
    return request;
  };

  await assert.rejects(
    boundedHttpRequest({
      url: 'http://127.0.0.1:1',
      method: 'POST',
      body: Buffer.from('{}'),
      connectTimeoutMs: 100,
      responseTimeoutMs: 100,
      maxResponseBytes: 1024,
      requestFunction: stalledRequest,
      deadlineMonotonicMs: 5,
      monotonicClock: () => monotonicNow,
    }),
    (error) => error.code === 'request_expired',
  );
  assert.equal(writeCalled, false);
  assert.equal(endCalled, false);
});

test('transport cannot resolve a response ending at the monotonic deadline', async () => {
  let monotonicNow = 0;
  const boundaryRequest = (url, options, onResponse) => {
    const request = new EventEmitter();
    const socket = new EventEmitter();
    socket.connecting = false;
    request.write = () => true;
    request.destroy = () => {};
    request.end = () => queueMicrotask(() => {
      request.emit('socket', socket);
      const incoming = new EventEmitter();
      incoming.headers = {};
      incoming.statusCode = 200;
      incoming.destroy = () => {};
      onResponse(incoming);
      queueMicrotask(() => {
        monotonicNow = 5;
        incoming.emit('end');
      });
    });
    return request;
  };

  await assert.rejects(
    boundedHttpRequest({
      url: 'http://127.0.0.1:1',
      method: 'GET',
      connectTimeoutMs: 100,
      responseTimeoutMs: 100,
      maxResponseBytes: 1024,
      requestFunction: boundaryRequest,
      deadlineMonotonicMs: 5,
      monotonicClock: () => monotonicNow,
    }),
    (error) => error.code === 'response_deadline',
  );
});

test('model inventory requires exact pinned name and digest', async (t) => {
  await t.test('exact pin', async () => {
    await withServer((request, response) => {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(fixtureBytes('ollama-inventory-valid.json'));
    }, async (baseUrl) => {
      const transport = new OllamaTransport(transportConfig(baseUrl), () => 0);
      const verified = await transport.verifyPinnedModel();
      assert.deepEqual(verified, runtime.config.pinned_model);
    });
  });

  await t.test('digest mismatch', async () => {
    await withServer((request, response) => {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(fixtureBytes('ollama-inventory-wrong-digest.json'));
    }, async (baseUrl) => {
      const transport = new OllamaTransport(transportConfig(baseUrl), () => 0);
      await assert.rejects(() => transport.verifyPinnedModel(), (error) => error.code === 'model_digest_mismatch');
    });
  });

  await t.test('name/model inconsistency', async () => {
    const body = Buffer.from(JSON.stringify({
      models: [{
        name: runtime.config.pinned_model.name,
        model: 'other:7b',
        digest: runtime.config.pinned_model.digest,
      }],
    }));
    await withServer((request, response) => {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(body);
    }, async (baseUrl) => {
      const transport = new OllamaTransport(transportConfig(baseUrl), () => 0);
      await assert.rejects(() => transport.verifyPinnedModel(), (error) => error.code === 'pinned_model_unavailable');
    });
  });

  await t.test('wrong optional member type', async () => {
    const inventory = fixtureJson('ollama-inventory-valid.json');
    inventory.models[0].size = '4683087332';
    await withServer((request, response) => {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(Buffer.from(JSON.stringify(inventory)));
    }, async (baseUrl) => {
      const transport = new OllamaTransport(transportConfig(baseUrl), () => 0);
      await assert.rejects(() => transport.verifyPinnedModel(), (error) => error.code === 'invalid_model_inventory');
    });
  });
});

test('Ollama request is pinned, server-free, tool-free and keeps user text separate', async () => {
  let captured;
  await withServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      captured = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(fixtureBytes('ollama-response-valid.json'));
    });
  }, async (baseUrl) => {
    const transport = new OllamaTransport(transportConfig(baseUrl), () => 0);
    const input = transportInput();
    const result = await transport.infer(input);
    assert.equal(result.request_id, input.request.request_id);
    assert.equal(result.bot_guid, input.request.bot_guid);
    assert.equal(result.model, runtime.config.pinned_model.name);
    assert.match(result.text, /^Ich /);
    assert.equal(transport.postAttempts, 1);
  });
  assert.equal(captured.model, 'qwen2.5:7b');
  assert.equal(captured.stream, false);
  assert.equal(captured.messages[0].role, 'system');
  assert.equal(captured.messages[1].role, 'user');
  assert.equal(captured.messages[1].content, makeRequest().message);
  assert.equal(Object.hasOwn(captured, 'tools'), false);
});

test('malformed UTF-8, invalid schema, tool calls, wrong role and wrong model fail closed with one POST', async (t) => {
  const cases = [
    {
      name: 'malformed UTF-8',
      body: fixtureHexBytes('malformed-utf8.hex'),
      code: 'invalid_utf8',
    },
    {
      name: 'invalid JSON',
      body: Buffer.from('{bad json'),
      code: 'invalid_json',
    },
    {
      name: 'tool call',
      body: fixtureBytes('ollama-response-tool-call.json'),
      code: 'schema_unknown_field',
    },
    {
      name: 'wrong role',
      body: Buffer.from(JSON.stringify({ ...fixtureJson('ollama-response-valid.json'), message: { role: 'tool', content: 'x' } })),
      code: 'invalid_assistant_role',
    },
    {
      name: 'wrong model',
      body: Buffer.from(JSON.stringify({ ...fixtureJson('ollama-response-valid.json'), model: 'other:7b' })),
      code: 'response_model_mismatch',
    },
    {
      name: 'wrong optional member type',
      body: Buffer.from(JSON.stringify({ ...fixtureJson('ollama-response-valid.json'), total_duration: '1000' })),
      code: 'invalid_inference_schema',
    },
    {
      name: 'empty assistant output',
      body: Buffer.from(JSON.stringify({ ...fixtureJson('ollama-response-valid.json'), message: { role: 'assistant', content: '   \n' } })),
      code: 'empty_assistant_text',
    },
    {
      name: 'assistant output over character limit',
      body: Buffer.from(JSON.stringify({ ...fixtureJson('ollama-response-valid.json'), message: { role: 'assistant', content: 'x'.repeat(241) } })),
      code: 'assistant_text_too_long',
    },
  ];

  for (const item of cases) {
    await t.test(item.name, async () => {
      await withServer((request, response) => {
        request.resume();
        response.writeHead(200, { 'Content-Type': 'application/json' });
        response.end(item.body);
      }, async (baseUrl) => {
        const transport = new OllamaTransport(transportConfig(baseUrl), () => 0);
        await assert.rejects(() => transport.infer(transportInput()), (error) => error.code === item.code);
        assert.equal(transport.postAttempts, 1);
      });
    });
  }
});

test('oversized raw inference response is rejected before JSON parsing', async () => {
  await withServer((request, response) => {
    request.resume();
    const body = Buffer.alloc(1025, 0x61);
    response.writeHead(200, { 'Content-Length': body.length });
    response.end(body);
  }, async (baseUrl) => {
    const transport = new OllamaTransport(transportConfig(baseUrl, { max_raw_response_bytes: 1024 }), () => 0);
    await assert.rejects(
      () => transport.infer(transportInput()),
      (error) => error.code === 'raw_response_too_large',
    );
    assert.equal(transport.postAttempts, 1);
  });
});

test('transport expiry uses only the passed monotonic deadline, not wire UTC', async () => {
  const transport = new OllamaTransport(transportConfig('http://127.0.0.1:1'), () => 5000);
  const input = transportInput(1, 5000);
  assert.equal(input.request.expires_utc, '2030-01-01T00:00:30.000Z');
  await assert.rejects(
    () => transport.infer(input),
    (error) => error.code === 'request_expired',
  );
  assert.equal(transport.postAttempts, 0);
});

test('one monotonic lifetime deadline bounds the complete HTTP attempt', async () => {
  await withServer((request) => request.resume(), async (baseUrl) => {
    const monotonicClock = () => performance.now();
    const transport = new OllamaTransport(
      transportConfig(baseUrl, { connect_timeout_ms: 1000, response_timeout_ms: 1000 }),
      monotonicClock,
    );
    const started = monotonicClock();
    await assert.rejects(
      () => transport.infer(transportInput(2, started + 50)),
      (error) => error.code === 'response_deadline',
    );
    assert.ok(monotonicClock() - started < 500);
    assert.equal(transport.postAttempts, 1);
  });
});

test('connection failure is terminal and never retried', async () => {
  const server = http.createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  await new Promise((resolve) => server.close(resolve));
  const transport = new OllamaTransport(
    transportConfig(`http://127.0.0.1:${address.port}`, { connect_timeout_ms: 100 }),
    () => 0,
  );
  await assert.rejects(
    () => transport.infer(transportInput()),
    (error) => error.code === 'connect_failed' || error.code === 'connect_deadline',
  );
  assert.equal(transport.postAttempts, 1);
});
