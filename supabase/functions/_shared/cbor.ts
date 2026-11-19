// A minimal CBOR (RFC 8949) decoder for App Attest objects: unsigned and negative integers, byte
// and text strings, arrays, maps and the simple values false/true/null. Indefinite lengths,
// floats and tags are not used by Apple and are rejected.

export class CborError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CborError";
  }
}

export type CborValue =
  | number
  | Uint8Array
  | string
  | boolean
  | null
  | CborValue[]
  | Map<CborValue, CborValue>;

const textDecoder = new TextDecoder("utf-8", { fatal: true });
const MAX_DEPTH = 16;

/** Decodes exactly one CBOR item; trailing bytes are an error. */
export function decodeCbor(bytes: Uint8Array): CborValue {
  const reader = { bytes, offset: 0 };
  const value = readItem(reader, 0);
  if (reader.offset !== bytes.length) {
    throw new CborError("Trailing bytes after the CBOR item");
  }
  return value;
}

interface Reader {
  bytes: Uint8Array;
  offset: number;
}

function take(reader: Reader, count: number): Uint8Array {
  if (count < 0 || reader.offset + count > reader.bytes.length) {
    throw new CborError("Unexpected end of CBOR data");
  }
  const slice = reader.bytes.subarray(reader.offset, reader.offset + count);
  reader.offset += count;
  return slice;
}

function readLength(reader: Reader, info: number): number {
  if (info < 24) return info;
  const size = info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : info === 27 ? 8 : 0;
  if (size === 0) throw new CborError("Unsupported CBOR length encoding");
  let value = 0;
  for (const byte of take(reader, size)) {
    value = value * 256 + byte;
  }
  if (!Number.isSafeInteger(value)) throw new CborError("CBOR integer too large");
  return value;
}

function readItem(reader: Reader, depth: number): CborValue {
  if (depth > MAX_DEPTH) throw new CborError("CBOR nesting too deep");
  const initial = take(reader, 1)[0];
  const major = initial >> 5;
  const info = initial & 0x1f;
  switch (major) {
    case 0:
      return readLength(reader, info);
    case 1:
      return -1 - readLength(reader, info);
    case 2:
      return take(reader, readLength(reader, info)).slice();
    case 3:
      try {
        return textDecoder.decode(take(reader, readLength(reader, info)));
      } catch (error) {
        if (error instanceof CborError) throw error;
        throw new CborError("Invalid UTF-8 in a CBOR text string");
      }
    case 4: {
      const count = readLength(reader, info);
      const items: CborValue[] = [];
      for (let i = 0; i < count; i++) items.push(readItem(reader, depth + 1));
      return items;
    }
    case 5: {
      const count = readLength(reader, info);
      const map = new Map<CborValue, CborValue>();
      for (let i = 0; i < count; i++) {
        const key = readItem(reader, depth + 1);
        map.set(key, readItem(reader, depth + 1));
      }
      return map;
    }
    case 7:
      if (info === 20) return false;
      if (info === 21) return true;
      if (info === 22) return null;
      throw new CborError("Unsupported CBOR simple value");
    default:
      throw new CborError("Unsupported CBOR type");
  }
}

/** Reads a text-keyed map entry. */
export function field(value: CborValue, key: string): CborValue | undefined {
  if (!(value instanceof Map)) throw new CborError("Expected a CBOR map");
  return value.get(key);
}
