// Apple App Attestation Root CA: the trust anchor for App Attest attestations.
//
// Canonical source: https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
// apple.com was not reachable from the environment that wrote this file, so the PEM was taken
// from two independent npm packages that embed it, appattest-checker-node@1.0.3
// (dist/attestation.js) and node-app-attest@2.2.0 (src/verifyAttestation.js), which agree byte
// for byte. Nothing was invented.
// Subject: CN=Apple App Attestation Root CA, O=Apple Inc., ST=California
// Valid: 2020-03-18 to 2045-03-15.
// SHA-256 fingerprint (pinned below and checked at load time; a mismatch fails every check):
//   1C:B9:82:3B:A2:8B:A6:AD:2D:33:A0:06:94:1D:E2:AE:4F:51:3E:F1:D4:E8:31:B9:F7:E0:FA:7B:62:42:C9:32
// Owner check (recommended once): download the .pem above on your Mac and run
//   openssl x509 -in Apple_App_Attestation_Root_CA.pem -noout -fingerprint -sha256
// The output must equal the fingerprint above.

import { x509 } from "./deps.ts";

export const APPLE_APP_ATTESTATION_ROOT_SHA256 =
  "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932";

export const APPLE_APP_ATTESTATION_ROOT_PEM = `
-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----
`;

let cached: Promise<x509.X509Certificate> | undefined;

/** The bundled root, after checking its fingerprint. */
export function appAttestRootCertificate(): Promise<x509.X509Certificate> {
  cached ??= (async () => {
    const cert = new x509.X509Certificate(APPLE_APP_ATTESTATION_ROOT_PEM.trim());
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", cert.rawData));
    const hex = Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
    if (hex !== APPLE_APP_ATTESTATION_ROOT_SHA256) {
      throw new Error(
        `Bundled Apple App Attestation Root CA fingerprint mismatch (got ${hex}); refusing to trust it`,
      );
    }
    return cert;
  })();
  return cached;
}
