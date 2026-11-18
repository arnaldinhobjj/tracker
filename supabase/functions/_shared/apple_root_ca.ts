// Apple Root CA - G3: the trust anchor for every JWS signed by the App Store
// (StoreKit 2 transactions, renewal info, App Store Server Notifications V2, Server API).
//
// Canonical source: https://www.apple.com/certificateauthority/AppleRootCA-G3.cer (DER).
// The bytes below were taken from the copy embedded in Apple's official
// @apple/app-store-server-library (npm 3.1.0, REAL_APPLE_ROOT_BASE64_ENCODED) and converted with
//   openssl x509 -inform DER -in AppleRootCA-G3.cer -out AppleRootCA-G3.pem
// because apple.com was not reachable from the environment that wrote this file. Their SHA-256
// matches the well-known fingerprint below (also pinned by the app-store-server-api package).
// Subject: CN=Apple Root CA - G3, OU=Apple Certification Authority, O=Apple Inc., C=US
// Valid: 2014-04-30 to 2039-04-30.
// SHA-256 fingerprint (pinned below and checked at load time):
//   63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79
// To re-check independently: download the .cer above and run
//   openssl x509 -inform DER -in AppleRootCA-G3.cer -noout -fingerprint -sha256

import { x509 } from "./deps.ts";

export const APPLE_ROOT_CA_G3_SHA256 =
  "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";

export const APPLE_ROOT_CA_G3_PEM = `
-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----
`.trim();

let cached: Promise<x509.X509Certificate> | undefined;

/** Returns the bundled Apple root after checking its pinned SHA-256 fingerprint. */
export function appleRootCertificate(): Promise<x509.X509Certificate> {
  cached ??= (async () => {
    const cert = new x509.X509Certificate(APPLE_ROOT_CA_G3_PEM);
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", cert.rawData));
    const hex = Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
    if (hex !== APPLE_ROOT_CA_G3_SHA256) {
      throw new Error(
        `Bundled Apple Root CA - G3 fingerprint mismatch (got ${hex}); refusing to trust it`,
      );
    }
    return cert;
  })();
  return cached;
}
