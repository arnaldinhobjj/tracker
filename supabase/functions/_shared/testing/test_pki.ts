// Test-only PKI: a throwaway root/intermediate/leaf shaped like Apple's App Store chain
// (P-384 root, P-256 intermediate and leaf, Apple marker extensions), and a JWS signer.
// Nothing here is used by the deployed functions.

import { x509 } from "../deps.ts";
import { APPLE_INTERMEDIATE_OID, APPLE_LEAF_OID, base64UrlEncode } from "../jws.ts";

const DAY = 24 * 60 * 60 * 1000;

export interface TestChain {
  root: x509.X509Certificate;
  intermediate: x509.X509Certificate;
  leaf: x509.X509Certificate;
  leafKey: CryptoKey;
}

export interface ChainOptions {
  now?: Date;
  /** Make the leaf certificate expired at `now`. */
  expiredLeaf?: boolean;
  /** Omit Apple's marker extension from the leaf. */
  withoutLeafOid?: boolean;
}

const ecdsa384 = { name: "ECDSA", namedCurve: "P-384", hash: "SHA-384" } as const;
const ecdsa256 = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as const;

async function keyPair(alg: { name: string; namedCurve: string }): Promise<CryptoKeyPair> {
  return await crypto.subtle.generateKey(alg, true, ["sign", "verify"]) as CryptoKeyPair;
}

function marker(oid: string): x509.Extension {
  // Apple's marker extensions carry an ASN.1 NULL (05 00).
  return new x509.Extension(oid, false, new Uint8Array([0x05, 0x00]));
}

export async function createTestChain(options: ChainOptions = {}): Promise<TestChain> {
  const now = options.now ?? new Date();
  const rootKeys = await keyPair(ecdsa384);
  const intermediateKeys = await keyPair(ecdsa256);
  const leafKeys = await keyPair(ecdsa256);

  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01",
    name: "CN=Test Root CA - G3, O=DayLedger Tests",
    notBefore: new Date(now.getTime() - 365 * DAY),
    notAfter: new Date(now.getTime() + 3650 * DAY),
    keys: rootKeys,
    signingAlgorithm: ecdsa384,
    extensions: [
      new x509.BasicConstraintsExtension(true, undefined, true),
      new x509.KeyUsagesExtension(
        x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign,
        true,
      ),
    ],
  });

  const intermediate = await x509.X509CertificateGenerator.create({
    serialNumber: "02",
    subject: "CN=Test WWDR Intermediate, O=DayLedger Tests",
    issuer: root.subject,
    notBefore: new Date(now.getTime() - 300 * DAY),
    notAfter: new Date(now.getTime() + 1000 * DAY),
    publicKey: intermediateKeys.publicKey,
    signingKey: rootKeys.privateKey,
    signingAlgorithm: ecdsa384,
    extensions: [
      new x509.BasicConstraintsExtension(true, 0, true),
      new x509.KeyUsagesExtension(
        x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign,
        true,
      ),
      marker(APPLE_INTERMEDIATE_OID),
    ],
  });

  const leafValidity = options.expiredLeaf
    ? { notBefore: new Date(now.getTime() - 400 * DAY), notAfter: new Date(now.getTime() - DAY) }
    : {
      notBefore: new Date(now.getTime() - 30 * DAY),
      notAfter: new Date(now.getTime() + 300 * DAY),
    };

  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "03",
    subject: "CN=Test App Store Signing, O=DayLedger Tests",
    issuer: intermediate.subject,
    ...leafValidity,
    publicKey: leafKeys.publicKey,
    signingKey: intermediateKeys.privateKey,
    signingAlgorithm: ecdsa256,
    extensions: [
      new x509.BasicConstraintsExtension(false, undefined, true),
      new x509.KeyUsagesExtension(x509.KeyUsageFlags.digitalSignature, true),
      ...(options.withoutLeafOid ? [] : [marker(APPLE_LEAF_OID)]),
    ],
  });

  return { root, intermediate, leaf, leafKey: leafKeys.privateKey };
}

function certBase64(cert: x509.X509Certificate): string {
  let binary = "";
  for (const byte of new Uint8Array(cert.rawData)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Signs `payload` as an App Store JWS (ES256, x5c = leaf, intermediate, root). */
export async function signJws(
  payload: unknown,
  chain: TestChain,
  overrides: { x5c?: string[]; alg?: string } = {},
): Promise<string> {
  const encoder = new TextEncoder();
  const header = {
    alg: overrides.alg ?? "ES256",
    x5c: overrides.x5c ??
      [certBase64(chain.leaf), certBase64(chain.intermediate), certBase64(chain.root)],
  };
  const input = `${base64UrlEncode(encoder.encode(JSON.stringify(header)))}.${
    base64UrlEncode(encoder.encode(JSON.stringify(payload)))
  }`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    chain.leafKey,
    encoder.encode(input),
  );
  return `${input}.${base64UrlEncode(signature)}`;
}

export { certBase64 };
