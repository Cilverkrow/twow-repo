import process from 'node:process';
import { dirname, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';

import { BoundedBridge } from './bridge.mjs';
import { loadRuntimeConfiguration } from './configuration.mjs';
import { assertExactKeys } from './contracts.mjs';
import { BridgeError, asBridgeError } from './errors.mjs';
import { acquireInstanceLock } from './instance-lock.mjs';
import { strictLines } from './ndjson.mjs';
import { parseJsonBytesStrict } from './strict-json.mjs';
import { OllamaTransport } from './transport.mjs';

const mode = process.argv[2];

try {
  if (mode === '--validate-only') {
    const runtime = loadRuntimeConfiguration();
    writeJson({
      result: 'PHASE1A_CONFIG_VALIDATION=PASS',
      bot_guid: runtime.context.bot_guid,
      profile_version: runtime.context.profile_version,
      context_sha256: runtime.context_sha256,
      model: runtime.config.pinned_model,
    });
  } else if (mode === '--run') {
    await runBridge();
  } else {
    process.stderr.write('Usage: node src/cli.mjs --validate-only | --run\n');
    process.exitCode = 2;
  }
} catch (error) {
  const bridgeError = asBridgeError(error);
  writeJson({ result: 'PHASE1A_BRIDGE_ERROR', code: bridgeError.code, message: bridgeError.message });
  process.exitCode = 1;
}

async function runBridge() {
  const artifactRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const instanceLock = acquireInstanceLock(resolve(artifactRoot, 'evidence/.phase1a-instance.lock'));
  try {
    await runOwnedBridge();
  } finally {
    instanceLock.release();
  }
}

async function runOwnedBridge() {
  const runtime = loadRuntimeConfiguration();
  const monotonicClock = () => performance.now();
  const transport = new OllamaTransport(runtime.config, monotonicClock);
  const bridge = new BoundedBridge({ ...runtime, transport, monotonicClock });
  let shutdownRequested = false;
  let signalShutdownTask = null;

  const stopFromSignal = () => {
    if (shutdownRequested) return;
    shutdownRequested = true;
    signalShutdownTask = bridge.shutdown({ drain: false });
    process.stdin.destroy();
  };
  process.once('SIGINT', stopFromSignal);
  process.once('SIGTERM', stopFromSignal);

  try {
    try {
      await bridge.start();
    } catch (error) {
      if (!signalShutdownTask) throw error;
      await signalShutdownTask;
      return;
    }
    if (shutdownRequested) return;

    writeJson({
      code: 'ready',
      mode: 'server_free_ndjson',
      active_limit: 1,
      waiting_capacity: runtime.config.waiting_capacity,
      ledger_capacity: runtime.config.ledger_capacity,
      bot_guid: runtime.context.bot_guid,
      model: runtime.config.pinned_model.name,
    });

    for await (const line of strictLines(process.stdin, runtime.config.max_request_json_bytes)) {
      if (shutdownRequested) break;
      try {
        const command = parseJsonBytesStrict(line, {
          label: 'bridge command',
          maxBytes: runtime.config.max_request_json_bytes,
          maxDepth: 10,
          rejectBom: true,
        });
        const result = handleCommand(command, bridge);
        if (result instanceof Promise) {
          shutdownRequested = true;
          writeJson({ code: 'shutdown', metrics: await result });
          break;
        }
        writeJson(result);
      } catch (error) {
        const bridgeError = asBridgeError(error);
        writeJson({ code: bridgeError.code, message: bridgeError.message });
      }
    }
  } finally {
    process.removeListener('SIGINT', stopFromSignal);
    process.removeListener('SIGTERM', stopFromSignal);
    if (signalShutdownTask) {
      writeJson({ code: 'shutdown', metrics: await signalShutdownTask });
    } else if (!shutdownRequested) {
      await bridge.shutdown({ drain: true });
    }
  }
}

function handleCommand(command, bridge) {
  if (command === null || typeof command !== 'object' || Array.isArray(command) || typeof command.command !== 'string') {
    throw new BridgeError('invalid_command', 'command must be an object with a string command field');
  }
  if (command.command === 'submit') {
    assertExactKeys(command, ['command', 'request'], 'submit command');
    return bridge.submitBytes(Buffer.from(JSON.stringify(command.request), 'utf8'));
  }
  if (command.command === 'status') {
    assertExactKeys(command, ['command', 'request_id', 'bot_guid'], 'status command');
    return bridge.getStatus(command.request_id, command.bot_guid);
  }
  if (command.command === 'consume') {
    assertExactKeys(command, ['command', 'request_id', 'bot_guid'], 'consume command');
    return bridge.consume(command.request_id, command.bot_guid);
  }
  if (command.command === 'shutdown') {
    assertExactKeys(command, ['command', 'drain'], 'shutdown command');
    if (typeof command.drain !== 'boolean') throw new BridgeError('invalid_command', 'shutdown drain must be boolean');
    return bridge.shutdown({ drain: command.drain });
  }
  if (command.command === 'metrics') {
    assertExactKeys(command, ['command'], 'metrics command');
    return { code: 'metrics', metrics: bridge.metrics() };
  }
  throw new BridgeError('unknown_command', `unknown command: ${command.command}`);
}

function writeJson(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}
