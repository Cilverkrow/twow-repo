export class BridgeError extends Error {
  constructor(code, message, details = undefined) {
    super(message, details === undefined ? undefined : { cause: details });
    this.name = 'BridgeError';
    this.code = code;
    this.details = details;
  }
}

export function asBridgeError(error, fallbackCode = 'internal_error') {
  if (error instanceof BridgeError) {
    return error;
  }
  return new BridgeError(fallbackCode, error instanceof Error ? error.message : String(error));
}
