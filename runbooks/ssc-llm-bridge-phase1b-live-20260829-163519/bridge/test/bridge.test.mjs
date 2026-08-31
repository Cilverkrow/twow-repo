import test from 'node:test';
import assert from 'node:assert/strict';

import { BoundedBridge } from '../src/bridge.mjs';
import { BridgeError } from '../src/errors.mjs';
import {
  ControlledTransport,
  FIXED_NOW_MS,
  ManualClock,
  abortableGate,
  clonedConfig,
  deferred,
  eventually,
  makeRequest,
  requestBytes,
  runtime,
  successfulTransportResult,
} from './helpers.mjs';

function createBridge({ transport = new ControlledTransport(), clock = new ManualClock(), config = runtime.config } = {}) {
  const bridge = new BoundedBridge({
    config,
    context: runtime.context,
    transport,
    wallClock: clock.wallNow,
    monotonicClock: clock.monotonicNow,
  });
  return { bridge, transport, clock };
}

test('valid request follows queued-running-ready-consumed and delivers exactly once', async () => {
  const { bridge, transport } = createBridge();
  await bridge.start();
  const submitted = bridge.submitBytes(requestBytes(1));
  assert.equal(submitted.accepted, true);
  assert.equal(submitted.status.state, 'queued');

  await eventually(() => bridge.getStatus(makeRequest(1).request_id, 18281).status.state === 'ready');
  const first = bridge.consume(makeRequest(1).request_id, 18281);
  assert.equal(first.code, 'consumed');
  assert.equal(first.status.state, 'consumed');
  assert.equal(first.completion.outcome, 'ready');
  assert.equal(first.completion.request_id, makeRequest(1).request_id);
  assert.equal(first.completion.bot_guid, 18281);
  assert.equal(first.completion.attempt_count, 1);
  assert.equal(first.completion.text, 'Ich halte heute die Augen offen.');
  assert.ok(Object.isFrozen(first.completion));
  assert.ok(Object.isFrozen(first.status));

  const second = bridge.consume(makeRequest(1).request_id, 18281);
  assert.equal(second.code, 'already_consumed');
  assert.equal(second.completion, null);
  assert.equal(transport.calls.length, 1);
  const metrics = await bridge.shutdown();
  assert.equal(metrics.lifecycle, 'stopped');
  assert.equal(metrics.active, 0);
  assert.equal(metrics.worker_settled, true);
});

test('single worker preserves FIFO and exact waiting capacity; queue-full is a keyed terminal tombstone', async () => {
  const gates = [deferred(), deferred(), deferred()];
  const transport = new ControlledTransport((args, index) =>
    abortableGate(args.signal, gates[index], () => successfulTransportResult(args.request)),
  );
  const { bridge } = createBridge({ transport });
  await bridge.start();

  assert.equal(bridge.submitBytes(requestBytes(1)).code, 'queued');
  await eventually(() => transport.active === 1);
  assert.equal(bridge.submitBytes(requestBytes(2)).code, 'queued');
  assert.equal(bridge.submitBytes(requestBytes(3)).code, 'queued');
  const full = bridge.submitBytes(requestBytes(4));
  assert.equal(full.code, 'queue_full');
  assert.equal(full.status.state, 'failed');
  assert.equal(full.status.attempt_count, 0);
  assert.equal(bridge.submitBytes(requestBytes(4)).code, 'duplicate');
  const fullCompletion = bridge.consume(makeRequest(4).request_id, 18281).completion;
  assert.equal(fullCompletion.error_code, 'queue_full');
  assert.equal(fullCompletion.attempt_count, 0);

  gates[0].resolve();
  await eventually(() => transport.calls.length === 2);
  gates[1].resolve();
  await eventually(() => transport.calls.length === 3);
  gates[2].resolve();
  await eventually(() => bridge.getStatus(makeRequest(3).request_id, 18281).status.state === 'ready');

  assert.deepEqual(transport.calls, [makeRequest(1).request_id, makeRequest(2).request_id, makeRequest(3).request_id]);
  assert.equal(transport.maxActive, 1);
  assert.equal(bridge.metrics().max_active_observed, 1);
  assert.equal(bridge.metrics().inference_attempts, 3);
  await bridge.shutdown();
});

test('duplicate and request-id/GUID mismatch never enqueue another inference', async () => {
  const gate = deferred();
  const transport = new ControlledTransport((args) =>
    abortableGate(args.signal, gate, () => successfulTransportResult(args.request)),
  );
  const { bridge } = createBridge({ transport });
  await bridge.start();
  assert.equal(bridge.submitBytes(requestBytes(1)).code, 'queued');
  await eventually(() => transport.calls.length === 1);
  assert.equal(bridge.submitBytes(requestBytes(1, { message: 'Anderer Text' })).code, 'duplicate');
  assert.equal(bridge.submitBytes(requestBytes(1, { bot_guid: 18282 })).code, 'identity_mismatch');
  assert.equal(transport.calls.length, 1);
  assert.throws(
    () => bridge.submitBytes(requestBytes(2, { bot_guid: 18282 })),
    (error) => error.code === 'personality_guid_mismatch',
  );
  gate.resolve();
  await eventually(() => bridge.getStatus(makeRequest(1).request_id, 18281).status.state === 'ready');
  await bridge.shutdown();
});

test('transport failure is terminal with one attempt and no retry', async () => {
  const transport = new ControlledTransport(() => {
    throw new BridgeError('response_deadline', 'synthetic deadline');
  });
  const { bridge } = createBridge({ transport });
  await bridge.start();
  bridge.submitBytes(requestBytes(1));
  await eventually(() => bridge.getStatus(makeRequest(1).request_id, 18281).status.state === 'failed');
  const consumed = bridge.consume(makeRequest(1).request_id, 18281);
  assert.equal(consumed.completion.error_code, 'response_deadline');
  assert.equal(consumed.completion.attempt_count, 1);
  assert.equal(transport.calls.length, 1);
  assert.equal(bridge.metrics().inference_attempts, 1);
  await bridge.shutdown();
});

test('completion key mismatch and response-model mismatch fail closed', async (t) => {
  await t.test('key mismatch', async () => {
    const transport = new ControlledTransport((args) => successfulTransportResult(args.request, { bot_guid: 99999 }));
    const { bridge } = createBridge({ transport });
    await bridge.start();
    bridge.submitBytes(requestBytes(1));
    await eventually(() => bridge.getStatus(makeRequest(1).request_id, 18281).status.state === 'failed');
    const consumed = bridge.consume(makeRequest(1).request_id, 18281);
    assert.equal(consumed.completion.error_code, 'completion_mismatch');
    assert.equal(transport.calls.length, 1);
    await bridge.shutdown();
  });

  await t.test('model mismatch', async () => {
    const transport = new ControlledTransport((args) => successfulTransportResult(args.request, { model: 'other:7b' }));
    const { bridge } = createBridge({ transport });
    await bridge.start();
    bridge.submitBytes(requestBytes(2));
    await eventually(() => bridge.getStatus(makeRequest(2).request_id, 18281).status.state === 'failed');
    const consumed = bridge.consume(makeRequest(2).request_id, 18281);
    assert.equal(consumed.completion.error_code, 'response_model_mismatch');
    assert.equal(transport.calls.length, 1);
    await bridge.shutdown();
  });
});

test('expired queued work makes zero attempts and stale running text is discarded', async (t) => {
  await t.test('queued expiry', async () => {
    const gate = deferred();
    const clock = new ManualClock();
    const transport = new ControlledTransport((args) =>
      abortableGate(args.signal, gate, () => successfulTransportResult(args.request)),
    );
    const { bridge } = createBridge({ transport, clock });
    await bridge.start();
    bridge.submitBytes(requestBytes(1));
    await eventually(() => transport.calls.length === 1);
    bridge.submitBytes(requestBytes(2, { expires_utc: new Date(FIXED_NOW_MS + 5000).toISOString() }));
    clock.advance(6000);
    gate.resolve();
    await eventually(() => bridge.getStatus(makeRequest(2).request_id, 18281).status.state === 'expired');
    const completion = bridge.consume(makeRequest(2).request_id, 18281).completion;
    assert.equal(completion.error_code, 'expired_before_run');
    assert.equal(completion.attempt_count, 0);
    assert.equal(completion.text, null);
    assert.equal(transport.calls.length, 1);
    await bridge.shutdown();
  });

  await t.test('stale running result', async () => {
    const gate = deferred();
    const clock = new ManualClock();
    const transport = new ControlledTransport((args) =>
      abortableGate(args.signal, gate, () => successfulTransportResult(args.request, { text: 'Dieser Text darf nie ausgeliefert werden.' })),
    );
    const { bridge } = createBridge({ transport, clock });
    await bridge.start();
    bridge.submitBytes(requestBytes(3, { expires_utc: new Date(FIXED_NOW_MS + 5000).toISOString() }));
    await eventually(() => transport.calls.length === 1);
    clock.advance(5000);
    gate.resolve();
    await eventually(() => bridge.getStatus(makeRequest(3).request_id, 18281).status.state === 'expired');
    const completion = bridge.consume(makeRequest(3).request_id, 18281).completion;
    assert.equal(completion.error_code, 'stale_result');
    assert.equal(completion.text, null);
    assert.equal(completion.attempt_count, 1);
    await bridge.shutdown();
  });
});

test('already-expired admission becomes expired without inference', async () => {
  const { bridge, transport } = createBridge();
  await bridge.start();
  const request = requestBytes(1, {
    created_utc: new Date(FIXED_NOW_MS - 10000).toISOString(),
    expires_utc: new Date(FIXED_NOW_MS - 1000).toISOString(),
  });
  const submitted = bridge.submitBytes(request);
  assert.equal(submitted.code, 'expired');
  assert.equal(submitted.status.state, 'expired');
  assert.equal(transport.calls.length, 0);
  await bridge.shutdown();
});

test('ready result that expires before consumption discards dialogue text', async () => {
  const clock = new ManualClock();
  const { bridge } = createBridge({ clock });
  await bridge.start();
  bridge.submitBytes(requestBytes(1, { expires_utc: new Date(FIXED_NOW_MS + 5000).toISOString() }));
  await eventually(() => bridge.getStatus(makeRequest(1).request_id, 18281).status.state === 'ready');
  clock.advance(5000);
  const duplicate = bridge.submitBytes(requestBytes(1, { expires_utc: new Date(FIXED_NOW_MS + 5000).toISOString() }));
  assert.equal(duplicate.code, 'duplicate');
  assert.equal(duplicate.status.state, 'expired');
  const consumed = bridge.consume(makeRequest(1).request_id, 18281);
  assert.equal(consumed.completion.outcome, 'expired');
  assert.equal(consumed.completion.error_code, 'expired_before_consume');
  assert.equal(consumed.completion.text, null);
  await bridge.shutdown();
});

test('accepted lifetime is fixed to one admission-derived monotonic deadline', async (t) => {
  await t.test('forward wall jump cannot prematurely expire queued or running work', async () => {
    const gate = deferred();
    const clock = new ManualClock();
    const observed = [];
    const transport = new ControlledTransport((args, index) => {
      observed.push(args);
      if (index === 0) {
        return abortableGate(args.signal, gate, () => successfulTransportResult(args.request));
      }
      return successfulTransportResult(args.request);
    });
    const { bridge } = createBridge({ transport, clock });
    const expiry = new Date(FIXED_NOW_MS + 5000).toISOString();
    await bridge.start();
    bridge.submitBytes(requestBytes(10, { expires_utc: expiry }));
    await eventually(() => transport.calls.length === 1);
    const queued = bridge.submitBytes(requestBytes(11, { expires_utc: expiry }));

    assert.equal(observed[0].deadlineMonotonicMs, 5000);
    assert.equal(observed[0].request.created_utc, new Date(FIXED_NOW_MS).toISOString());
    assert.equal(observed[0].request.expires_utc, expiry);
    assert.equal(Object.hasOwn(observed[0].request, 'deadlineMonotonicMs'), false);
    assert.equal(Object.hasOwn(queued.status, 'deadlineMonotonicMs'), false);

    clock.jumpWall(60 * 60 * 1000);
    assert.equal(bridge.getStatus(makeRequest(10).request_id, 18281).status.state, 'running');
    assert.equal(bridge.getStatus(makeRequest(11).request_id, 18281).status.state, 'queued');

    gate.resolve();
    await eventually(() => bridge.getStatus(makeRequest(11).request_id, 18281).status.state === 'ready');
    assert.equal(observed[1].deadlineMonotonicMs, 5000);
    const completion = bridge.consume(makeRequest(11).request_id, 18281).completion;
    assert.equal(completion.outcome, 'ready');
    assert.equal(Object.hasOwn(completion, 'deadlineMonotonicMs'), false);
    await bridge.shutdown();
  });

  await t.test('backward wall jump cannot extend queued work or replace its deadline on duplicate', async () => {
    const gate = deferred();
    const clock = new ManualClock();
    const transport = new ControlledTransport((args) =>
      abortableGate(args.signal, gate, () => successfulTransportResult(args.request)),
    );
    const { bridge } = createBridge({ transport, clock });
    const shortExpiry = new Date(FIXED_NOW_MS + 5000).toISOString();
    await bridge.start();
    bridge.submitBytes(requestBytes(20));
    await eventually(() => transport.calls.length === 1);
    bridge.submitBytes(requestBytes(21, { expires_utc: shortExpiry }));
    const duplicate = bridge.submitBytes(requestBytes(21, {
      expires_utc: new Date(FIXED_NOW_MS + 30000).toISOString(),
    }));
    assert.equal(duplicate.code, 'duplicate');

    clock.jumpWall(-60 * 60 * 1000);
    clock.advanceMonotonic(5000);
    const status = bridge.getStatus(makeRequest(21).request_id, 18281).status;
    assert.equal(status.state, 'expired');
    assert.equal(bridge.consume(makeRequest(21).request_id, 18281).completion.error_code, 'expired_before_run');
    assert.equal(transport.calls.length, 1);

    gate.resolve();
    await eventually(() => bridge.getStatus(makeRequest(20).request_id, 18281).status.state === 'ready');
    await bridge.shutdown();
  });

  await t.test('backward wall jump cannot extend running work', async () => {
    const gate = deferred();
    const clock = new ManualClock();
    const transport = new ControlledTransport((args) =>
      abortableGate(args.signal, gate, () => successfulTransportResult(args.request, {
        text: 'Dieser verspätete Text darf nicht ausgeliefert werden.',
      })),
    );
    const { bridge } = createBridge({ transport, clock });
    await bridge.start();
    bridge.submitBytes(requestBytes(30, {
      expires_utc: new Date(FIXED_NOW_MS + 5000).toISOString(),
    }));
    await eventually(() => transport.calls.length === 1);

    clock.jumpWall(-60 * 60 * 1000);
    clock.advanceMonotonic(5000);
    gate.resolve();
    await eventually(() => bridge.getStatus(makeRequest(30).request_id, 18281).status.state === 'expired');
    const completion = bridge.consume(makeRequest(30).request_id, 18281).completion;
    assert.equal(completion.error_code, 'stale_result');
    assert.equal(completion.text, null);
    await bridge.shutdown();
  });

  await t.test('forward wall jump cannot prematurely expire ready-before-consume work', async () => {
    const clock = new ManualClock();
    const { bridge } = createBridge({ clock });
    await bridge.start();
    bridge.submitBytes(requestBytes(40, {
      expires_utc: new Date(FIXED_NOW_MS + 5000).toISOString(),
    }));
    await eventually(() => bridge.getStatus(makeRequest(40).request_id, 18281).status.state === 'ready');

    clock.jumpWall(60 * 60 * 1000);
    const consumed = bridge.consume(makeRequest(40).request_id, 18281);
    assert.equal(consumed.completion.outcome, 'ready');
    await bridge.shutdown();
  });

  await t.test('backward wall jump cannot extend ready-before-consume work', async () => {
    const clock = new ManualClock();
    const { bridge } = createBridge({ clock });
    await bridge.start();
    bridge.submitBytes(requestBytes(50, {
      expires_utc: new Date(FIXED_NOW_MS + 5000).toISOString(),
    }));
    await eventually(() => bridge.getStatus(makeRequest(50).request_id, 18281).status.state === 'ready');

    clock.jumpWall(-60 * 60 * 1000);
    clock.advanceMonotonic(5000);
    const consumed = bridge.consume(makeRequest(50).request_id, 18281);
    assert.equal(consumed.completion.outcome, 'expired');
    assert.equal(consumed.completion.error_code, 'expired_before_consume');
    assert.equal(consumed.completion.text, null);
    await bridge.shutdown();
  });
});

test('consume race has one winner and never redelivers dialogue', async () => {
  const { bridge } = createBridge();
  await bridge.start();
  bridge.submitBytes(requestBytes(1));
  await eventually(() => bridge.getStatus(makeRequest(1).request_id, 18281).status.state === 'ready');
  const [first, second] = await Promise.all([
    Promise.resolve().then(() => bridge.consume(makeRequest(1).request_id, 18281)),
    Promise.resolve().then(() => bridge.consume(makeRequest(1).request_id, 18281)),
  ]);
  assert.deepEqual([first.code, second.code].sort(), ['already_consumed', 'consumed']);
  assert.equal([first.completion, second.completion].filter(Boolean).length, 1);
  await bridge.shutdown();
});

test('bounded ledger fails closed without transport attempts', async () => {
  const gate = deferred();
  const config = clonedConfig({ waiting_capacity: 1, ledger_capacity: 2 });
  const transport = new ControlledTransport((args) =>
    abortableGate(args.signal, gate, () => successfulTransportResult(args.request)),
  );
  const { bridge } = createBridge({ transport, config });
  await bridge.start();
  bridge.submitBytes(requestBytes(1));
  await eventually(() => transport.calls.length === 1);
  bridge.submitBytes(requestBytes(2));
  assert.equal(bridge.submitBytes(requestBytes(3)).code, 'ledger_full');
  assert.equal(transport.calls.length, 1);
  gate.resolve();
  await eventually(() => bridge.getStatus(makeRequest(2).request_id, 18281).status.state === 'ready');
  assert.equal(transport.calls.length, 2);
  await bridge.shutdown();
});

test('controlled immediate shutdown closes admission, cancels active, fails queued and joins worker', async () => {
  const gate = deferred();
  const transport = new ControlledTransport((args) =>
    abortableGate(args.signal, gate, () => successfulTransportResult(args.request)),
  );
  const { bridge } = createBridge({ transport });
  await bridge.start();
  bridge.submitBytes(requestBytes(1));
  await eventually(() => transport.calls.length === 1);
  bridge.submitBytes(requestBytes(2));
  const metrics = await bridge.shutdown({ drain: false, timeoutMs: 1000 });
  assert.equal(metrics.lifecycle, 'stopped');
  assert.equal(metrics.active, 0);
  assert.equal(metrics.worker_settled, true);
  assert.equal(transport.calls.length, 1);
  assert.throws(() => bridge.submitBytes(requestBytes(3)), (error) => error.code === 'admission_closed');
  assert.equal(bridge.consume(makeRequest(1).request_id, 18281).completion.error_code, 'shutdown_cancelled');
  assert.equal(bridge.consume(makeRequest(2).request_id, 18281).completion.error_code, 'shutdown_cancelled');
  assert.deepEqual(await bridge.shutdown(), metrics);
});

test('invalid shutdown options do not poison a later controlled shutdown', async () => {
  const { bridge } = createBridge();
  await bridge.start();
  assert.throws(
    () => bridge.shutdown({ timeoutMs: 0 }),
    (error) => error.code === 'invalid_shutdown_timeout',
  );
  assert.throws(
    () => bridge.shutdown({ drain: 'yes' }),
    (error) => error.code === 'invalid_shutdown_mode',
  );
  assert.equal(bridge.metrics().lifecycle, 'running');
  assert.equal(bridge.metrics().accepting, true);
  const metrics = await bridge.shutdown({ drain: true, timeoutMs: 1000 });
  assert.equal(metrics.lifecycle, 'stopped');
  assert.equal(metrics.worker_settled, true);
});

test('shutdown during model verification cancels and joins startup without opening admission', async () => {
  let observedSignal;
  const transport = {
    verifyPinnedModel(signal) {
      observedSignal = signal;
      return new Promise((resolve, reject) => {
        signal.addEventListener(
          'abort',
          () => reject(new BridgeError('request_cancelled', 'synthetic startup cancellation')),
          { once: true },
        );
      });
    },
    async infer() {
      throw new Error('inference must not run');
    },
  };
  const { bridge } = createBridge({ transport });
  const startTask = bridge.start();
  const startRejection = assert.rejects(startTask, (error) => error.code === 'startup_cancelled');
  const shutdownTask = bridge.shutdown({ drain: false, timeoutMs: 1000 });
  await startRejection;
  const metrics = await shutdownTask;
  assert.equal(observedSignal.aborted, true);
  assert.equal(metrics.lifecycle, 'stopped');
  assert.equal(metrics.accepting, false);
  assert.equal(metrics.worker_owned, false);
  assert.equal(metrics.worker_settled, true);
  assert.throws(() => bridge.submitBytes(requestBytes(1)), (error) => error.code === 'admission_closed');
});

test('controlled drain shutdown completes queued work before joining', async () => {
  const { bridge, transport } = createBridge();
  await bridge.start();
  bridge.submitBytes(requestBytes(1));
  bridge.submitBytes(requestBytes(2));
  const metrics = await bridge.shutdown({ drain: true, timeoutMs: 1000 });
  assert.equal(metrics.lifecycle, 'stopped');
  assert.equal(transport.calls.length, 2);
  assert.equal(bridge.getStatus(makeRequest(1).request_id, 18281).status.state, 'ready');
  assert.equal(bridge.getStatus(makeRequest(2).request_id, 18281).status.state, 'ready');
});

test('drain deadline cancels active work, fails queued work and still joins the owned worker', async () => {
  const gate = deferred();
  const transport = new ControlledTransport((args) =>
    abortableGate(args.signal, gate, () => successfulTransportResult(args.request)),
  );
  const { bridge } = createBridge({ transport });
  await bridge.start();
  bridge.submitBytes(requestBytes(1));
  await eventually(() => transport.calls.length === 1);
  bridge.submitBytes(requestBytes(2));
  const metrics = await bridge.shutdown({ drain: true, timeoutMs: 25 });
  assert.equal(metrics.lifecycle, 'stopped');
  assert.equal(metrics.active, 0);
  assert.equal(metrics.worker_settled, true);
  assert.equal(transport.calls.length, 1);
  assert.equal(bridge.consume(makeRequest(1).request_id, 18281).completion.error_code, 'shutdown_timeout');
  assert.equal(bridge.consume(makeRequest(2).request_id, 18281).completion.error_code, 'shutdown_timeout');
});

test('expired queued tombstones do not consume waiting capacity', async () => {
  const gate = deferred();
  const clock = new ManualClock();
  const transport = new ControlledTransport((args) =>
    abortableGate(args.signal, gate, () => successfulTransportResult(args.request)),
  );
  const { bridge } = createBridge({ transport, clock });
  await bridge.start();
  bridge.submitBytes(requestBytes(1));
  await eventually(() => transport.calls.length === 1);
  const shortExpiry = new Date(FIXED_NOW_MS + 5000).toISOString();
  bridge.submitBytes(requestBytes(2, { expires_utc: shortExpiry }));
  bridge.submitBytes(requestBytes(3, { expires_utc: shortExpiry }));
  clock.advance(6000);
  assert.equal(bridge.submitBytes(requestBytes(4)).code, 'queued');
  assert.equal(bridge.getStatus(makeRequest(2).request_id, 18281).status.state, 'expired');
  assert.equal(bridge.getStatus(makeRequest(3).request_id, 18281).status.state, 'expired');
  gate.resolve();
  await eventually(() => bridge.getStatus(makeRequest(4).request_id, 18281).status.state === 'ready');
  await bridge.shutdown();
});

test('startup fails closed when pinned inventory verification fails', async () => {
  const transport = new ControlledTransport(undefined, new BridgeError('model_digest_mismatch', 'synthetic mismatch'));
  const { bridge } = createBridge({ transport });
  await assert.rejects(() => bridge.start(), (error) => error.code === 'model_digest_mismatch');
  assert.equal(transport.verifyCalls, 1);
  assert.equal(transport.calls.length, 0);
  assert.throws(() => bridge.submitBytes(requestBytes(1)), (error) => error.code === 'admission_closed');
  assert.equal(bridge.metrics().lifecycle, 'failed');
});

test('malformed request bytes and schema errors make zero attempts', async () => {
  const { bridge, transport } = createBridge();
  await bridge.start();
  for (const bytes of [
    Buffer.from([0xc3, 0x28]),
    Buffer.from('{not json', 'utf8'),
    Buffer.from(JSON.stringify({ ...makeRequest(1), extra: true }), 'utf8'),
  ]) {
    assert.throws(() => bridge.submitBytes(bytes));
  }
  assert.equal(transport.calls.length, 0);
  await bridge.shutdown();
});
