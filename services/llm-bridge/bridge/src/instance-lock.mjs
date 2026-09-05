import { closeSync, existsSync, openSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

import { BridgeError } from './errors.mjs';

export function acquireInstanceLock(lockPath) {
  const token = randomUUID();
  let descriptor;
  try {
    descriptor = openSync(lockPath, 'wx', 0o600);
  } catch (error) {
    if (error?.code === 'EEXIST') {
      throw new BridgeError('instance_lock_held', 'another Phase 1A bridge instance may already own the inference slot');
    }
    throw new BridgeError('instance_lock_failed', 'could not create the Phase 1A instance lock', error);
  }

  const contents = `${JSON.stringify({ schema_version: 1, token, pid: process.pid, started_utc: new Date().toISOString() })}\n`;
  try {
    writeFileSync(descriptor, contents, { encoding: 'utf8' });
  } catch (error) {
    closeSync(descriptor);
    try {
      unlinkSync(lockPath);
    } catch {
      // A failed cleanup leaves a safe fail-closed lock.
    }
    throw new BridgeError('instance_lock_failed', 'could not initialize the Phase 1A instance lock', error);
  }

  let released = false;
  return Object.freeze({
    release() {
      if (released) return;
      released = true;
      closeSync(descriptor);
      try {
        if (existsSync(lockPath) && JSON.parse(readFileSync(lockPath, 'utf8')).token === token) {
          unlinkSync(lockPath);
        }
      } catch (error) {
        throw new BridgeError('instance_lock_release_failed', 'could not safely release the Phase 1A instance lock', error);
      }
    },
  });
}
