// Test-only App Attest: a throwaway root/intermediate shaped like Apple's App Attestation CA, and
// a fake device that produces attestations and assertions exactly as DCAppAttestService does.
// Nothing here is used by the deployed functions.

import { x509 } from "../deps.ts";
import { APP_ATTEST_NONCE_OID, base64Encode, concatBytes, sha256 } from "../app_attest.ts";

const DAY = 24 * 60 * 60 * 1000;
const encoder = new TextEncoder();
const ecdsa384 = { name: "ECDSA", namedCurve: "P-384", hash: "SHA-384" } as const;
const ecdsa256 = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as const;

// MARK: CBOR encoding (the subset App Attest uses)

type Encodable = number | string | Uint8Array | Encodable[] | { [key: string]: Encodable };

function head(major: number, length: number): Uint8Array {
  if (length < 24) return new Uint8Array([(major << 5) | length]);
  if (length < 0x100) return new Uint8Array([(major << 5) | 24, length]);
  if (length < 0x10000) return new Uint8Array([(major << 5) | 25, length >> 8, length & 0xff]);
  return new Uint8Array([
    (major << 5) | 26,
    (length >>> 24) & 0xff,
    (length >> 16) & 0xff,
    (length >> 8) & 0xff,
    length & 0xff,
  ]);
}

export function encodeCbor(value: Encodable): Uint8Array {
  if (typeof value === "number") return head(0, value);
  if (typeof value === "string") {
    const bytes = encoder.encode(value);
    return concatBytes(head(3, bytes.length), bytes);
  }
  if (value instanceof Uint8Array) return concatBytes(head(2, value.length), value);
  if (Array.isArray(value)) return concatBytes(head(4, value.length), ...value.map(encodeCbor));
  const entries = Object.entries(value);
  return concatBytes(
    head(5, entries.length),
    ...entries.flatMap(([k, v]) => [encodeCbor(k), encodeCbor(v)]),
  );
}

// MARK: DER helpers

function derLength(length: number): Uint8Array {
  return length < 0x80 ? new Uint8Array([length]) : new Uint8Array([0x81, length]);
}

function der(tag: number, content: Uint8Array): Uint8Array<ArrayBuffer> {
  return concatBytes(new Uint8Array([tag]), derLength(content.length), content);
}

/** Raw r||s (WebCrypto) to the DER form App Attest sends. */
export function rawSignatureToDer(raw: Uint8Array): Uint8Array {
  const integer = (bytes: Uint8Array) => {
    let i = 0;
    while (i < bytes.length - 1 && bytes[i] === 0) i++;
    const trimmed = bytes.subarray(i);
    return der(0x02, trimmed[0] & 0x80 ? concatBytes(new Uint8Array([0]), trimmed) : trimmed);
  };
  return der(0x30, concatBytes(integer(raw.subarray(0, 32)), integer(raw.subarray(32))));
}

// MARK: CA

export interface AttestCA {
  root: x509.X509Certificate;
  intermediate: x509.X509Certificate;
  intermediateKey: CryptoKey;
}

async function keyPair(alg: { name: string; namedCurve: string }): Promise<CryptoKeyPair> {
  return await crypto.subtle.generateKey(alg, true, ["sign", "verify"]) as CryptoKeyPair;
}

export async function createAttestCA(now = new Date()): Promise<AttestCA> {
  const rootKeys = await keyPair(ecdsa384);
  const intermediateKeys = await keyPair(ecdsa384);
  const caExtensions = [
    new x509.BasicConstraintsExtension(true, 0, true),
    new x509.KeyUsagesExtension(x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign, true),
  ];
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: "CN=Test App Attestation Root CA, O=DayLedger Tests",
    notBefore: new Date(now.getTime() - 365 * DAY),
    notAfter: new Date(now.getTime() + 3650 * DAY),
    keys: rootKeys,
    signingAlgorithm: ecdsa384,
    extensions: [new x509.BasicConstraintsExtension(true, undefined, true), caExtensions[1]],
  });
  const intermediate = await x509.X509CertificateGenerator.create({
    serialNumber: "02",
    subject: "CN=Test App Attestation CA 1, O=DayLedger Tests",
    issuer: root.subject,
    notBefore: new Date(now.getTime() - 300 * DAY),
    notAfter: new Date(now.getTime() + 1000 * DAY),
    publicKey: intermediateKeys.publicKey,
    signingKey: rootKeys.privateKey,
    signingAlgorithm: ecdsa384,
    extensions: caExtensions,
  });
  return { root, intermediate, intermediateKey: intermediateKeys.privateKey };
}

// MARK: Device

export interface AttestOverrides {
  /** Sign the credential certificate with another CA (not trusted). */
  signer?: AttestCA;
  appId?: string;
  environment?: "production" | "development";
  /** Put a different nonce in the certificate. */
  wrongNonce?: boolean;
  counter?: number;
}

export class FakeDevice {
  private constructor(
    readonly keyId: string,
    private readonly keys: CryptoKeyPair,
    private readonly appId: string,
    private readonly ca: AttestCA,
  ) {}

  static async create(appId: string, ca: AttestCA): Promise<FakeDevice> {
    const keys = await crypto.subtle.generateKey(ecdsa256, true, [
      "sign",
      "verify",
    ]) as CryptoKeyPair;
    const point = new Uint8Array(await crypto.subtle.exportKey("raw", keys.publicKey));
    return new FakeDevice(base64Encode(await sha256(point)), keys, appId, ca);
  }

  /** What `attestKey(keyId, clientDataHash: SHA256(challenge))` returns, base64. */
  async attest(challenge: string, overrides: AttestOverrides = {}): Promise<string> {
    const signer = overrides.signer ?? this.ca;
    const credentialId = Uint8Array.from(atob(this.keyId), (c) => c.charCodeAt(0));
    const aaguid = encoder.encode(
      overrides.environment === "development" ? "appattestdevelop" : "appattest\0\0\0\0\0\0\0",
    );
    const counter = new Uint8Array(4);
    new DataView(counter.buffer).setUint32(0, overrides.counter ?? 0);
    const authData = concatBytes(
      await sha256(encoder.encode(overrides.appId ?? this.appId)),
      new Uint8Array([0x40]),
      counter,
      aaguid,
      new Uint8Array([0, credentialId.length]),
      credentialId,
      encodeCbor({ "1": 2 }), // stand-in for the COSE key (not checked)
    );
    const nonce = overrides.wrongNonce
      ? crypto.getRandomValues(new Uint8Array(32))
      : await sha256(authData, await sha256(encoder.encode(challenge)));
    const now = new Date();
    const credential = await x509.X509CertificateGenerator.create({
      serialNumber: "0a",
      subject: "CN=" + this.keyId.slice(0, 16).replace(/[^A-Za-z0-9]/g, "x"),
      issuer: signer.intermediate.subject,
      notBefore: new Date(now.getTime() - DAY),
      notAfter: new Date(now.getTime() + 30 * DAY),
      publicKey: this.keys.publicKey,
      signingKey: signer.intermediateKey,
      signingAlgorithm: ecdsa384,
      extensions: [
        new x509.Extension(APP_ATTEST_NONCE_OID, false, der(0x30, der(0xa1, der(0x04, nonce)))),
      ],
    });
    return base64Encode(encodeCbor({
      fmt: "apple-appattest",
      attStmt: {
        x5c: [new Uint8Array(credential.rawData), new Uint8Array(signer.intermediate.rawData)],
        receipt: new Uint8Array([1, 2, 3]),
      },
      authData,
    }));
  }

  /** What `generateAssertion(keyId, clientDataHash: SHA256(clientData))` returns, base64. */
  async assert(clientData: Uint8Array, counter: number, appId = this.appId): Promise<string> {
    const count = new Uint8Array(4);
    new DataView(count.buffer).setUint32(0, counter);
    const authenticatorData = concatBytes(
      await sha256(encoder.encode(appId)),
      new Uint8Array([0]),
      count,
    );
    const nonce = await sha256(authenticatorData, await sha256(clientData));
    const raw = new Uint8Array(
      await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, this.keys.privateKey, nonce),
    );
    return base64Encode(encodeCbor({ signature: rawSignatureToDer(raw), authenticatorData }));
  }
}

/** An in-memory registry, as the Postgres functions behave. */
export class MemoryAttestRegistry {
  readonly keys = new Map<string, { publicKey: string; counter: number; environment: string }>();
  readonly challenges = new Map<string, Date>();
  constructor(private readonly now: () => Date = () => new Date()) {}

  getKey(keyId: string) {
    const key = this.keys.get(keyId);
    return Promise.resolve(key ? { publicKey: key.publicKey, counter: key.counter } : null);
  }
  advanceCounter(keyId: string, counter: number) {
    const key = this.keys.get(keyId);
    if (!key || key.counter >= counter) return Promise.resolve(false);
    key.counter = counter;
    return Promise.resolve(true);
  }
  saveChallenge(challenge: string, expiresAt: Date) {
    this.challenges.set(challenge, expiresAt);
    return Promise.resolve();
  }
  consumeChallenge(challenge: string) {
    const expiresAt = this.challenges.get(challenge);
    this.challenges.delete(challenge);
    return Promise.resolve(expiresAt !== undefined && expiresAt > this.now());
  }
  saveKey(key: { keyId: string; publicKey: string; counter: number; environment: string }) {
    if (!this.keys.has(key.keyId)) this.keys.set(key.keyId, { ...key });
    return Promise.resolve();
  }
}
