import { BridgeError } from './errors.mjs';

const UTF8_BOM = Buffer.from([0xef, 0xbb, 0xbf]);

export function decodeUtf8Strict(bytes, options = {}) {
  const {
    label = 'input',
    maxBytes = Number.MAX_SAFE_INTEGER,
    rejectBom = true,
  } = options;
  const buffer = Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes);

  if (buffer.length > maxBytes) {
    throw new BridgeError('input_too_large', `${label} exceeds ${maxBytes} bytes`);
  }
  if (rejectBom && buffer.length >= 3 && buffer.subarray(0, 3).equals(UTF8_BOM)) {
    throw new BridgeError('utf8_bom_forbidden', `${label} must be UTF-8 without a BOM`);
  }

  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buffer);
  } catch (error) {
    throw new BridgeError('invalid_utf8', `${label} is not valid UTF-8`, error);
  }
}

export function parseJsonBytesStrict(bytes, options = {}) {
  const text = decodeUtf8Strict(bytes, options);
  const parser = new StrictJsonParser(text, options.maxDepth ?? 16);
  const value = parser.parse();
  assertUnicodeScalars(value, options.label ?? 'input');
  return value;
}

function assertUnicodeScalars(value, label) {
  if (typeof value === 'string') {
    for (let index = 0; index < value.length; index += 1) {
      const unit = value.charCodeAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        const next = value.charCodeAt(index + 1);
        if (!(next >= 0xdc00 && next <= 0xdfff)) {
          throw new BridgeError('invalid_unicode_scalar', `${label} contains an unpaired high surrogate`);
        }
        index += 1;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw new BridgeError('invalid_unicode_scalar', `${label} contains an unpaired low surrogate`);
      }
    }
    return;
  }
  if (Array.isArray(value)) {
    for (const item of value) {
      assertUnicodeScalars(item, label);
    }
    return;
  }
  if (value !== null && typeof value === 'object') {
    for (const [key, item] of Object.entries(value)) {
      assertUnicodeScalars(key, label);
      assertUnicodeScalars(item, label);
    }
  }
}

class StrictJsonParser {
  constructor(text, maxDepth) {
    this.text = text;
    this.index = 0;
    this.maxDepth = maxDepth;
  }

  parse() {
    this.skipWhitespace();
    if (this.index === this.text.length) {
      this.fail('invalid_json', 'JSON input is empty');
    }
    const value = this.parseValue(0);
    this.skipWhitespace();
    if (this.index !== this.text.length) {
      this.fail('json_trailing_content', 'JSON has trailing content');
    }
    return value;
  }

  parseValue(depth) {
    if (depth > this.maxDepth) {
      this.fail('json_depth_exceeded', `JSON exceeds maximum depth ${this.maxDepth}`);
    }
    const character = this.text[this.index];
    if (character === '{') return this.parseObject(depth + 1);
    if (character === '[') return this.parseArray(depth + 1);
    if (character === '"') return this.parseString();
    if (character === 't') return this.parseLiteral('true', true);
    if (character === 'f') return this.parseLiteral('false', false);
    if (character === 'n') return this.parseLiteral('null', null);
    if (character === '-' || (character >= '0' && character <= '9')) return this.parseNumber();
    this.fail('invalid_json', `Unexpected JSON token at offset ${this.index}`);
  }

  parseObject(depth) {
    this.index += 1;
    this.skipWhitespace();
    const result = {};
    const keys = new Set();
    if (this.text[this.index] === '}') {
      this.index += 1;
      return result;
    }

    while (this.index < this.text.length) {
      if (this.text[this.index] !== '"') {
        this.fail('invalid_json', `Object key must be a string at offset ${this.index}`);
      }
      const key = this.parseString();
      if (keys.has(key)) {
        this.fail('duplicate_json_key', `Duplicate JSON key: ${key}`);
      }
      keys.add(key);
      this.skipWhitespace();
      if (this.text[this.index] !== ':') {
        this.fail('invalid_json', `Missing colon after object key at offset ${this.index}`);
      }
      this.index += 1;
      this.skipWhitespace();
      const memberValue = this.parseValue(depth);
      Object.defineProperty(result, key, {
        value: memberValue,
        enumerable: true,
        configurable: true,
        writable: true,
      });
      this.skipWhitespace();
      if (this.text[this.index] === '}') {
        this.index += 1;
        return result;
      }
      if (this.text[this.index] !== ',') {
        this.fail('invalid_json', `Missing comma in object at offset ${this.index}`);
      }
      this.index += 1;
      this.skipWhitespace();
    }
    this.fail('invalid_json', 'Unterminated JSON object');
  }

  parseArray(depth) {
    this.index += 1;
    this.skipWhitespace();
    const result = [];
    if (this.text[this.index] === ']') {
      this.index += 1;
      return result;
    }

    while (this.index < this.text.length) {
      result.push(this.parseValue(depth));
      this.skipWhitespace();
      if (this.text[this.index] === ']') {
        this.index += 1;
        return result;
      }
      if (this.text[this.index] !== ',') {
        this.fail('invalid_json', `Missing comma in array at offset ${this.index}`);
      }
      this.index += 1;
      this.skipWhitespace();
    }
    this.fail('invalid_json', 'Unterminated JSON array');
  }

  parseString() {
    const start = this.index;
    this.index += 1;
    while (this.index < this.text.length) {
      const character = this.text[this.index];
      if (character === '"') {
        this.index += 1;
        try {
          return JSON.parse(this.text.slice(start, this.index));
        } catch (error) {
          throw new BridgeError('invalid_json_string', `Invalid JSON string at offset ${start}`, error);
        }
      }
      if (character === '\\') {
        this.index += 1;
        const escape = this.text[this.index];
        if (escape === 'u') {
          const hex = this.text.slice(this.index + 1, this.index + 5);
          if (!/^[0-9a-fA-F]{4}$/.test(hex)) {
            this.fail('invalid_json_string', `Invalid Unicode escape at offset ${this.index}`);
          }
          this.index += 5;
          continue;
        }
        if (!'"\\/bfnrt'.includes(escape ?? '')) {
          this.fail('invalid_json_string', `Invalid escape at offset ${this.index}`);
        }
        this.index += 1;
        continue;
      }
      if (character.charCodeAt(0) <= 0x1f) {
        this.fail('invalid_json_string', `Unescaped control character at offset ${this.index}`);
      }
      this.index += 1;
    }
    this.fail('invalid_json_string', `Unterminated JSON string at offset ${start}`);
  }

  parseNumber() {
    const remaining = this.text.slice(this.index);
    const match = remaining.match(/^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/);
    if (match === null) {
      this.fail('invalid_json_number', `Invalid number at offset ${this.index}`);
    }
    this.index += match[0].length;
    const value = Number(match[0]);
    if (!Number.isFinite(value)) {
      this.fail('invalid_json_number', `Non-finite number at offset ${this.index}`);
    }
    return value;
  }

  parseLiteral(token, value) {
    if (this.text.slice(this.index, this.index + token.length) !== token) {
      this.fail('invalid_json', `Invalid literal at offset ${this.index}`);
    }
    this.index += token.length;
    return value;
  }

  skipWhitespace() {
    while (this.index < this.text.length && /[\u0009\u000a\u000d\u0020]/.test(this.text[this.index])) {
      this.index += 1;
    }
  }

  fail(code, message) {
    throw new BridgeError(code, message);
  }
}
