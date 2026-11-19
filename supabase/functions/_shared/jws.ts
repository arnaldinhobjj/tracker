// Verification of JWS objects signed by the App Store (StoreKit 2 transactions, renewal info,
// App Store Server Notifications V2 and App Store Server API responses).
//
// Apple signs these with ES256 and puts the certificate chain in the protected header's `x5c`:
//   x5c[0] leaf (signs the JWS)  <- x5c[1] Apple WWDR intermediate  <- x5c[2] Apple Root CA - G3
// We only trust the root we bundle (apple_root_ca.ts); the root in the header is just compared.

import { x509 } from "./deps.ts";
import { appleRootCertificate } from "./apple_root_ca.ts";

/** Marker extension Apple puts on the leaf that signs App Store receipts/JWS. */
export const APPLE_LEAF_OID = "1.2.840.113635.100.6.11.1";
/** Marker extension on the Apple Worldwide Developer Relations intermediate. */
export const APPLE_INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1";

export class JwsVerificationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "JwsVerificationError";
  }
}

export interface VerifyOptions {
  /** Trust anchor. Defaults to the bundled Apple Root CA - G3. Tests inject their own. */
  root?: x509.X509Certificate;
  /** The time at which certificates must be valid. Defaults to now. */
  now?: Date;
}

interface JwsHeader {
  alg?: string;
  x5c?: unknown;
}

const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();

export function base64UrlDecode(input: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]*$/.test(input)) {
    throw new JwsVerificationError("Malformed base64url segment");
  }
  const base64 = input.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function base64UrlEncode(bytes: Uint8Array | ArrayBuffer): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let binary = "";
  for (const byte of view) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64Decode(input: string): Uint8Array<ArrayBuffer> {
  const binary = atob(input);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function parseJsonSegment<T>(segment: string, what: string): T {
  try {
    return JSON.parse(textDecoder.decode(base64UrlDecode(segment))) as T;
  } catch {
    throw new JwsVerificationError(`Malformed JWS ${what}`);
  }
}

function equalBytes(a: ArrayBuffer, b: ArrayBuffer): boolean {
  if (a.byteLength !== b.byteLength) return false;
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

function checkValidity(cert: x509.X509Certificate, now: Date, label: string): void {
  if (now < cert.notBefore || now > cert.notAfter) {
    throw new JwsVerificationError(`The ${label} certificate is not valid at ${now.toISOString()}`);
  }
}

function isCa(cert: x509.X509Certificate): boolean {
  const bc = cert.getExtension(x509.BasicConstraintsExtension);
  return bc?.ca === true;
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

/**
 * Verifies an App Store JWS and returns its decoded payload. Throws JwsVerificationError when
 * anything is off: wrong algorithm, missing/short chain, chain not rooted in the trusted root,
 * a certificate outside its validity period, missing Apple marker extensions, or a bad signature.
 */
export async function verifyAppleJws<T>(jws: string, options: VerifyOptions = {}): Promise<T> {
  if (typeof jws !== "string" || jws.length === 0) {
    throw new JwsVerificationError("Empty JWS");
  }
  const parts = jws.split(".");
  if (parts.length !== 3) {
    throw new JwsVerificationError("A JWS must have three segments");
  }
  const [headerB64, payloadB64, signatureB64] = parts;
  const header = parseJsonSegment<JwsHeader>(headerB64, "header");
  if (header.alg !== "ES256") {
    throw new JwsVerificationError(`Unsupported JWS algorithm ${String(header.alg)}`);
  }
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.length !== 3 || !x5c.every((c) => typeof c === "string")) {
    throw new JwsVerificationError("The x5c header must contain exactly three certificates");
  }

  let leaf: x509.X509Certificate;
  let intermediate: x509.X509Certificate;
  let headerRoot: x509.X509Certificate;
  try {
    [leaf, intermediate, headerRoot] = (x5c as string[]).map((c) =>
      new x509.X509Certificate(base64Decode(c))
    );
  } catch {
    throw new JwsVerificationError("The x5c header contains an unreadable certificate");
  }

  const root = options.root ?? await appleRootCertificate();
  const now = options.now ?? new Date();

  if (!equalBytes(headerRoot.rawData, root.rawData)) {
    throw new JwsVerificationError("The certificate chain does not end in the trusted root");
  }
  checkValidity(root, now, "root");
  checkValidity(intermediate, now, "intermediate");
  checkValidity(leaf, now, "leaf");

  if (!isCa(intermediate)) {
    throw new JwsVerificationError("The intermediate certificate is not a CA");
  }
  if (!intermediate.getExtension(APPLE_INTERMEDIATE_OID)) {
    throw new JwsVerificationError("The intermediate is not an Apple WWDR certificate");
  }
  if (!leaf.getExtension(APPLE_LEAF_OID)) {
    throw new JwsVerificationError("The leaf is not an App Store signing certificate");
  }
  if (!(await signedBy(intermediate, root))) {
    throw new JwsVerificationError("The intermediate certificate is not signed by the root");
  }
  if (!(await signedBy(leaf, intermediate))) {
    throw new JwsVerificationError("The leaf certificate is not signed by the intermediate");
  }

  let key: CryptoKey;
  try {
    key = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"]);
  } catch {
    throw new JwsVerificationError("The leaf key is not a P-256 key");
  }
  const signature = base64UrlDecode(signatureB64);
  if (signature.length !== 64) {
    throw new JwsVerificationError("Malformed ES256 signature");
  }
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    signature,
    textEncoder.encode(`${headerB64}.${payloadB64}`),
  );
  if (!valid) {
    throw new JwsVerificationError("Invalid JWS signature");
  }
  return parseJsonSegment<T>(payloadB64, "payload");
}

/** Signature verifier signature, so callers can inject a fake in tests. */
export type JwsVerifier = <T>(jws: string) => Promise<T>;

export const defaultVerifier: JwsVerifier = <T>(jws: string) => verifyAppleJws<T>(jws);
