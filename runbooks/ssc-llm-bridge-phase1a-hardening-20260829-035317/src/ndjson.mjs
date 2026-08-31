import { BridgeError } from './errors.mjs';

export async function* strictLines(stream, maxLineBytes) {
  let pending = Buffer.alloc(0);
  for await (const chunk of stream) {
    pending = Buffer.concat([pending, chunk]);
    if (pending.length > maxLineBytes && pending.indexOf(0x0a) === -1) {
      throw new BridgeError('command_too_large', `NDJSON command exceeds ${maxLineBytes} bytes`);
    }
    let newlineIndex;
    while ((newlineIndex = pending.indexOf(0x0a)) !== -1) {
      let line = pending.subarray(0, newlineIndex);
      pending = pending.subarray(newlineIndex + 1);
      if (line.length > 0 && line[line.length - 1] === 0x0d) line = line.subarray(0, line.length - 1);
      if (line.length === 0) continue;
      if (line.length > maxLineBytes) throw new BridgeError('command_too_large', `NDJSON command exceeds ${maxLineBytes} bytes`);
      yield line;
    }
  }
  if (pending.length > 0) {
    if (pending.length > maxLineBytes) throw new BridgeError('command_too_large', `NDJSON command exceeds ${maxLineBytes} bytes`);
    yield pending;
  }
}
