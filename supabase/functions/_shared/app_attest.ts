// App Attest (DeviceCheck): proof that a request comes from the genuine DayLedger app on a real
// Apple device, for the functions that spend DayLedger's money or hold its secrets
// (truelayer-token, ai-suggest).
//
// 1. Registration (app-attest function): the app gets a one-time challenge, has the Secure Enclave
//    create a key and Apple attest it, and sends the attestation. We check it against Apple's
//    App Attestation root and store the key's public half and its counter.
// 2. Every protected request carries an assertion: the key's signature over the request body,
//    with a counter that must go up each time (so a captured request can't be replayed).
//
// Mode (APP_ATTEST_MODE): "off", "report" (verify and log, never block: the default, so older
// app versions and simulators keep working) or "enforce" (reject requests without a valid
// assertion). Reference: Apple, "Validating apps that connect to your server".

import { x509 } from "./deps.ts";
import { appAttestRootCertificate } from "./app_attest_root_ca.ts";
import { CborError, type CborValue, decodeCbor, field } from "./cbor.ts";
import { optionalEnv } from "./env.ts";
import { HttpError } from "./http.ts";

export const ATTEST_KEY_HEADER = "x-dayledger-attest-key";
export const ATTEST_ASSERTION_HEADER = "x-dayledger-attest-assertion";
/** Response header telling the app its key needs registering again (sent in "report" mode). */
export const ATTEST_STATUS_HEADER = "x-dayledger-attest";

/** Adds the hint for outcomes the app can fix by registering a new key. */
export function withAttestStatus(response: Response, outcome: AttestOutcome): Response {
  if (outcome === "unknown_key" || outcome === "invalid") {
    response.headers.set(ATTEST_STATUS_HEADER, "register");
  }
  return response;
}
/** The credential certificate's extension holding the attestation nonce. */
export const APP_ATTEST_NONCE_OID = "1.2.840.113635.100.8.2";
const AAGUID_PRODUCTION = "appattest\0\0\0\0\0\0\0";
const AAGUID_DEVELOPMENT = "appattestdevelop";
const CHALLENGE_TTL_MS = 5 * 60 * 1000;

export type AppAttestMode = "off" | "report" | "enforce";

export interface AppAttestConfig {
  /** "<Team ID>.<bundle ID>", e.g. "ABCDE12345.app.dayledger". */
  appId: string;
  mode: AppAttestMode;
  /** Accept keys from development builds (Xcode installs). Never in production. */
  allowDevelopment: boolean;
}

export function appAttestConfigFromEnv(): AppAttestConfig {
  const appId = optionalEnv("APP_ATTEST_APP_ID") ?? "";
  const mode = (optionalEnv("APP_ATTEST_MODE") ?? "report").toLowerCase();
  if (mode !== "off" && mode !== "report" && mode !== "enforce") {
    throw new Error("APP_ATTEST_MODE must be off, report or enforce");
  }
  if (appId && !/^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(appId)) {
    throw new Error("APP_ATTEST_APP_ID must be <Team ID>.<bundle ID>");
  }
  if (mode === "enforce" && !appId) {
    // Fail closed: enforcing without knowing the app would reject everyone silently.
    throw new Error("APP_ATTEST_MODE=enforce needs APP_ATTEST_APP_ID");
  }
  return {
    appId,
    mode: appId ? mode : "off",
    allowDevelopment: optionalEnv("APP_ATTEST_ALLOW_DEVELOPMENT") === "true",
  };
}

export class AttestationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AttestationError";
  }
}

// MARK: Bytes

const encoder = new TextEncoder();

export function concatBytes(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export async function sha256(...parts: Uint8Array[]): Promise<Uint8Array<ArrayBuffer>> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", concatBytes(...parts)));
}

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** Standard base64 (what Swift's `base64EncodedString()` produces). */
export function base64Decode(input: string, what: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9+/]*={0,2}$/.test(input) || input.length % 4 !== 0) {
    throw new AttestationError(`Malformed base64 ${what}`);
  }
  const binary = atob(input);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function base64Encode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

// MARK: DER (just enough for the nonce extension and ECDSA signatures)

interface Tlv {
  tag: number;
  content: Uint8Array;
}

function readTlv(bytes: Uint8Array, what: string): Tlv {
  if (bytes.length < 2) throw new AttestationError(`Malformed ${what}`);
  const tag = bytes[0];
  let length = bytes[1];
  let offset = 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 2 || bytes.length < 2 + count) {
      throw new AttestationError(`Malformed ${what}`);
    }
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[2 + i];
    offset += count;
  }
  if (offset + length !== bytes.length) throw new AttestationError(`Malformed ${what}`);
  return { tag, content: bytes.subarray(offset, offset + length) };
}

/** Splits a DER SEQUENCE's content into its elements. */
function readSequenceElements(content: Uint8Array, what: string): Tlv[] {
  const elements: Tlv[] = [];
  let offset = 0;
  while (offset < content.length) {
    if (content.length - offset < 2) throw new AttestationError(`Malformed ${what}`);
    let length = content[offset + 1];
    let header = 2;
    if (length & 0x80) {
      const count = length & 0x7f;
      if (count === 0 || count > 2) throw new AttestationError(`Malformed ${what}`);
      length = 0;
      for (let i = 0; i < count; i++) length = length * 256 + content[offset + 2 + i];
      header += count;
    }
    const end = offset + header + length;
    if (end > content.length) throw new AttestationError(`Malformed ${what}`);
    elements.push(readTlv(content.subarray(offset, end), what));
    offset = end;
  }
  return elements;
}

/** The nonce in the credential certificate: SEQUENCE { [1] EXPLICIT OCTET STRING (32 bytes) }. */
export function nonceFromExtension(value: Uint8Array): Uint8Array {
  const sequence = readTlv(value, "nonce extension");
  if (sequence.tag !== 0x30) throw new AttestationError("Malformed nonce extension");
  const [tagged] = readSequenceElements(sequence.content, "nonce extension");
  if (!tagged || tagged.tag !== 0xa1) throw new AttestationError("Malformed nonce extension");
  const octets = readTlv(tagged.content, "nonce extension");
  if (octets.tag !== 0x04 || octets.content.length !== 32) {
    throw new AttestationError("Malformed nonce extension");
  }
  return octets.content;
}

/** DER ECDSA signature (what App Attest produces) to the raw r||s form WebCrypto verifies. */
export function derSignatureToRaw(der: Uint8Array): Uint8Array<ArrayBuffer> {
  const sequence = readTlv(der, "signature");
  const parts = sequence.tag === 0x30 ? readSequenceElements(sequence.content, "signature") : [];
  if (parts.length !== 2 || parts.some((p) => p.tag !== 0x02)) {
    throw new AttestationError("Malformed signature");
  }
  const raw = new Uint8Array(64);
  parts.forEach((part, index) => {
    let integer = part.content;
    while (integer.length > 32 && integer[0] === 0) integer = integer.subarray(1);
    if (integer.length > 32) throw new AttestationError("Malformed signature");
    raw.set(integer, index * 32 + (32 - integer.length));
  });
  return raw;
}

// MARK: Authenticator data

interface AuthenticatorData {
  rpIdHash: Uint8Array;
  counter: number;
  aaguid?: string;
  credentialId?: Uint8Array;
}

function parseAuthenticatorData(bytes: Uint8Array, attested: boolean): AuthenticatorData {
  if (bytes.length < 37) throw new AttestationError("Authenticator data too short");
  const rpIdHash = bytes.subarray(0, 32);
  const counter = new DataView(bytes.buffer, bytes.byteOffset + 33, 4).getUint32(0);
  if (!attested) return { rpIdHash, counter };
  if (bytes.length < 55) throw new AttestationError("Authenticator data has no credential");
  const aaguid = String.fromCharCode(...bytes.subarray(37, 53));
  const idLength = (bytes[53] << 8) | bytes[54];
  if (bytes.length < 55 + idLength) throw new AttestationError("Authenticator data too short");
  return { rpIdHash, counter, aaguid, credentialId: bytes.subarray(55, 55 + idLength) };
}

function bytesField(value: CborValue, key: string): Uint8Array {
  const item = field(value, key);
  if (!(item instanceof Uint8Array)) throw new AttestationError(`Missing ${key}`);
  return item;
}

function decode(bytes: Uint8Array, what: string): CborValue {
  try {
    return decodeCbor(bytes);
  } catch (error) {
    if (error instanceof CborError) throw new AttestationError(`Malformed ${what}`);
    throw error;
  }
}

// MARK: Attestation

export interface RegisteredKey {
  keyId: string;
  /** The key's public half, as base64 SubjectPublicKeyInfo. */
  publicKey: string;
  counter: number;
  environment: "production" | "development";
}

export interface VerifyOptions {
  /** Trust anchor. Defaults to the bundled Apple App Attestation Root CA. Tests inject their own. */
  root?: x509.X509Certificate;
  now?: Date;
}

async function signedBy(
  cert: x509.X509Certificate,
  issuer: x509.X509Certificate,
): Promise<boolean> {
  if (cert.issuer !== issuer.subject) return false;
  try {
    return await cert.verify({ publicKey: issuer.publicKey, signatureOnly: true });
  } catch {
    return false;
  }
}

function checkValidity(cert: x509.X509Certificate, now: Date, label: string): void {
  if (now < cert.notBefore || now > cert.notAfter) {
    throw new AttestationError(`The ${label} certificate is not valid now`);
  }
}

/**
 * Verifies an attestation object from `DCAppAttestService.attestKey(_:clientDataHash:)`, where
 * the client data hash was SHA-256 of `challenge` (UTF-8). Returns the key to store.
 */
export async function verifyAttestation(
  input: { keyId: string; attestation: string; challenge: string },
  config: Pick<AppAttestConfig, "appId" | "allowDevelopment">,
  options: VerifyOptions = {},
): Promise<RegisteredKey> {
  const keyIdBytes = base64Decode(input.keyId, "key ID");
  if (keyIdBytes.length !== 32) throw new AttestationError("The key ID must be 32 bytes");
  const object = decode(base64Decode(input.attestation, "attestation"), "attestation");
  if (field(object, "fmt") !== "apple-appattest") {
    throw new AttestationError("Not an App Attest attestation");
  }
  const statement = field(object, "attStmt");
  const authData = bytesField(object, "authData");
  const x5c = statement === undefined ? undefined : field(statement, "x5c");
  if (!Array.isArray(x5c) || x5c.length < 2 || !x5c.every((c) => c instanceof Uint8Array)) {
    throw new AttestationError("The attestation has no certificate chain");
  }

  let credential: x509.X509Certificate;
  let intermediate: x509.X509Certificate;
  try {
    credential = new x509.X509Certificate(x5c[0] as Uint8Array<ArrayBuffer>);
    intermediate = new x509.X509Certificate(x5c[1] as Uint8Array<ArrayBuffer>);
  } catch {
    throw new AttestationError("The attestation contains an unreadable certificate");
  }
  const root = options.root ?? await appAttestRootCertificate();
  const now = options.now ?? new Date();
  checkValidity(intermediate, now, "intermediate");
  checkValidity(credential, now, "credential");
  if (intermediate.getExtension(x509.BasicConstraintsExtension)?.ca !== true) {
    throw new AttestationError("The intermediate certificate is not a CA");
  }
  if (!(await signedBy(intermediate, root))) {
    throw new AttestationError("The intermediate is not signed by Apple's App Attestation root");
  }
  if (!(await signedBy(credential, intermediate))) {
    throw new AttestationError("The credential certificate is not signed by the intermediate");
  }

  // The nonce binds the attestation to our one-time challenge.
  const nonce = await sha256(authData, await sha256(encoder.encode(input.challenge)));
  const extension = credential.getExtension(APP_ATTEST_NONCE_OID);
  if (!extension || !equalBytes(nonceFromExtension(new Uint8Array(extension.value)), nonce)) {
    throw new AttestationError("The attestation is not for this challenge");
  }

  // The key ID is the SHA-256 of the attested public key.
  let publicKey: CryptoKey;
  try {
    publicKey = await crypto.subtle.importKey(
      "spki",
      credential.publicKey.rawData,
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["verify"],
    );
  } catch {
    throw new AttestationError("The attested key is not a P-256 key");
  }
  const point = new Uint8Array(await crypto.subtle.exportKey("raw", publicKey));
  if (!equalBytes(await sha256(point), keyIdBytes)) {
    throw new AttestationError("The key ID doesn't match the attested key");
  }

  const data = parseAuthenticatorData(authData, true);
  if (!equalBytes(data.rpIdHash, await sha256(encoder.encode(config.appId)))) {
    throw new AttestationError("The attestation is for another app");
  }
  if (data.counter !== 0) throw new AttestationError("A new key's counter must be 0");
  let environment: RegisteredKey["environment"];
  if (data.aaguid === AAGUID_PRODUCTION) {
    environment = "production";
  } else if (data.aaguid === AAGUID_DEVELOPMENT && config.allowDevelopment) {
    environment = "development";
  } else {
    throw new AttestationError("The attestation is from an unexpected environment");
  }
  if (!data.credentialId || !equalBytes(data.credentialId, keyIdBytes)) {
    throw new AttestationError("The credential ID doesn't match the key ID");
  }
  return {
    keyId: input.keyId,
    publicKey: base64Encode(new Uint8Array(credential.publicKey.rawData)),
    counter: 0,
    environment,
  };
}

// MARK: Assertions

/**
 * Verifies an assertion from `DCAppAttestService.generateAssertion(_:clientDataHash:)`, where the
 * client data hash was SHA-256 of `clientData` (the request body). Returns the new counter,
 * which must be stored (and must be greater than `previousCounter`).
 */
export async function verifyAssertion(
  input: { assertion: string; clientData: Uint8Array },
  key: { publicKey: string; counter: number },
  appId: string,
): Promise<number> {
  const object = decode(base64Decode(input.assertion, "assertion"), "assertion");
  const signature = derSignatureToRaw(bytesField(object, "signature"));
  const authenticatorData = bytesField(object, "authenticatorData");
  const nonce = await sha256(authenticatorData, await sha256(input.clientData));

  let publicKey: CryptoKey;
  try {
    publicKey = await crypto.subtle.importKey(
      "spki",
      base64Decode(key.publicKey, "public key"),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
  } catch {
    throw new AttestationError("The stored key is unreadable");
  }
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    signature,
    nonce,
  );
  if (!valid) throw new AttestationError("Invalid assertion signature");

  const data = parseAuthenticatorData(authenticatorData, false);
  if (!equalBytes(data.rpIdHash, await sha256(encoder.encode(appId)))) {
    throw new AttestationError("The assertion is for another app");
  }
  if (data.counter <= key.counter) {
    throw new AttestationError("The assertion counter didn't increase (replayed request?)");
  }
  return data.counter;
}

// MARK: Storage

export interface AppAttestKeyStore {
  getKey(keyId: string): Promise<{ publicKey: string; counter: number } | null>;
  /** Stores `counter` if it is greater than the stored one. Returns whether it was. */
  advanceCounter(keyId: string, counter: number): Promise<boolean>;
}

export interface AppAttestRegistry extends AppAttestKeyStore {
  saveChallenge(challenge: string, expiresAt: Date): Promise<void>;
  /** Deletes the challenge; true if it existed and hadn't expired (one use only). */
  consumeChallenge(challenge: string): Promise<boolean>;
  saveKey(key: RegisteredKey): Promise<void>;
}

// MARK: The request gate

export type AttestOutcome = "disabled" | "verified" | "missing" | "unknown_key" | "invalid";

/**
 * Checks the request's assertion over `rawBody`. In "enforce" mode anything but a valid
 * assertion is rejected with 401 (`attestation_required`, `attest_key_unknown` or
 * `attestation_invalid`; the app re-registers on `attest_key_unknown`). In "report" mode the
 * outcome is only logged.
 */
export async function checkRequestAttestation(
  req: Request,
  rawBody: Uint8Array,
  config: AppAttestConfig,
  store: AppAttestKeyStore,
  log: (message: string) => void = console.warn,
): Promise<AttestOutcome> {
  if (config.mode === "off") return "disabled";
  const keyId = req.headers.get(ATTEST_KEY_HEADER);
  const assertion = req.headers.get(ATTEST_ASSERTION_HEADER);

  let outcome: AttestOutcome;
  let reason = "";
  if (!keyId || !assertion || keyId.length > 100 || assertion.length > 4_000) {
    outcome = "missing";
  } else {
    const key = await store.getKey(keyId);
    if (!key) {
      outcome = "unknown_key";
    } else {
      try {
        const counter = await verifyAssertion(
          { assertion, clientData: rawBody },
          key,
          config.appId,
        );
        // Atomic: of two requests with the same counter, only one gets through.
        outcome = await store.advanceCounter(keyId, counter) ? "verified" : "invalid";
        if (outcome === "invalid") reason = "counter already used";
      } catch (error) {
        if (!(error instanceof AttestationError)) throw error;
        outcome = "invalid";
        reason = error.message;
      }
    }
  }
  if (outcome === "verified") return outcome;

  log(`App Attest ${outcome}${reason ? `: ${reason}` : ""} (mode ${config.mode})`);
  if (config.mode === "enforce") {
    switch (outcome) {
      case "missing":
        throw new HttpError(401, "attestation_required", "Update DayLedger to continue.");
      case "unknown_key":
        throw new HttpError(401, "attest_key_unknown", "This device needs to register again.");
      default:
        throw new HttpError(401, "attestation_invalid", "This request couldn't be verified.");
    }
  }
  return outcome;
}

// MARK: Registration (the app-attest function)

function boundedString(value: unknown, name: string, max: number): string {
  if (typeof value !== "string" || value.length === 0 || value.length > max) {
    throw new HttpError(400, "invalid_request", `${name} is missing or too long.`);
  }
  return value;
}

function randomChallenge(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return base64Encode(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * `{"action": "challenge"}` returns `{"challenge": "..."}` (valid for 5 minutes, one use).
 * `{"action": "register", "keyId", "attestation", "challenge"}` verifies and stores the key.
 */
export async function handleAppAttest(
  body: Record<string, unknown>,
  config: AppAttestConfig,
  registry: AppAttestRegistry,
  options: VerifyOptions = {},
): Promise<Record<string, unknown>> {
  if (config.mode === "off") {
    throw new HttpError(503, "attestation_disabled", "App Attest isn't enabled on this server.");
  }
  const now = options.now ?? new Date();
  switch (body.action) {
    case "challenge": {
      const challenge = randomChallenge();
      await registry.saveChallenge(challenge, new Date(now.getTime() + CHALLENGE_TTL_MS));
      return { challenge };
    }
    case "register": {
      const keyId = boundedString(body.keyId, "keyId", 100);
      const attestation = boundedString(body.attestation, "attestation", 20_000);
      const challenge = boundedString(body.challenge, "challenge", 100);
      if (!(await registry.consumeChallenge(challenge))) {
        throw new HttpError(400, "invalid_challenge", "The challenge expired. Try again.");
      }
      let key: RegisteredKey;
      try {
        key = await verifyAttestation({ keyId, attestation, challenge }, config, options);
      } catch (error) {
        if (!(error instanceof AttestationError)) throw error;
        console.warn(`App Attest registration rejected: ${error.message}`);
        throw new HttpError(400, "attestation_invalid", "This device couldn't be verified.");
      }
      await registry.saveKey(key);
      return { registered: true };
    }
    default:
      throw new HttpError(400, "invalid_request", "Unknown action.");
  }
}
