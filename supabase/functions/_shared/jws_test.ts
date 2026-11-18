import { assertEquals, assertRejects } from "./test_deps.ts";
import { appleRootCertificate } from "./apple_root_ca.ts";
import { JwsVerificationError, verifyAppleJws } from "./jws.ts";
import { certBase64, createTestChain, signJws } from "./testing/test_pki.ts";

const payload = { transactionId: "2000000123", bundleId: "app.dayledger.DayLedger" };

Deno.test("bundled Apple Root CA - G3 loads and matches its pinned fingerprint", async () => {
  const root = await appleRootCertificate();
  assertEquals(root.subject.includes("CN=Apple Root CA - G3"), true);
  assertEquals(root.notAfter.toISOString(), "2039-04-30T18:19:06.000Z");
});

Deno.test("a JWS signed by a leaf chained to the trusted root verifies", async () => {
  const chain = await createTestChain();
  const jws = await signJws(payload, chain);
  assertEquals(await verifyAppleJws(jws, { root: chain.root }), payload);
});

Deno.test("a tampered payload fails signature verification", async () => {
  const chain = await createTestChain();
  const jws = await signJws(payload, chain);
  const [h, , s] = jws.split(".");
  const forged = btoa(JSON.stringify({ ...payload, bundleId: "evil" }))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  await assertRejects(
    () => verifyAppleJws(`${h}.${forged}.${s}`, { root: chain.root }),
    JwsVerificationError,
    "Invalid JWS signature",
  );
});

Deno.test("a signature from a different key fails", async () => {
  const chain = await createTestChain();
  const other = await createTestChain();
  // Header claims `chain`'s certificates but the signature comes from `other`'s leaf key.
  const jws = await signJws(payload, { ...chain, leafKey: other.leafKey });
  await assertRejects(
    () => verifyAppleJws(jws, { root: chain.root }),
    JwsVerificationError,
    "Invalid JWS signature",
  );
});

Deno.test("a chain that ends in a different root is rejected", async () => {
  const trusted = await createTestChain();
  const attacker = await createTestChain();
  const jws = await signJws(payload, attacker);
  await assertRejects(
    () => verifyAppleJws(jws, { root: trusted.root }),
    JwsVerificationError,
    "trusted root",
  );
});

Deno.test("an attacker cannot just append the trusted root to their own chain", async () => {
  const trusted = await createTestChain();
  const attacker = await createTestChain();
  const jws = await signJws(payload, attacker, {
    x5c: [certBase64(attacker.leaf), certBase64(attacker.intermediate), certBase64(trusted.root)],
  });
  await assertRejects(
    () => verifyAppleJws(jws, { root: trusted.root }),
    JwsVerificationError,
    "not signed by the root",
  );
});

Deno.test("an expired leaf certificate is rejected", async () => {
  const chain = await createTestChain({ expiredLeaf: true });
  const jws = await signJws(payload, chain);
  await assertRejects(
    () => verifyAppleJws(jws, { root: chain.root }),
    JwsVerificationError,
    "leaf certificate is not valid",
  );
});

Deno.test("certificates are checked at the given time", async () => {
  const chain = await createTestChain();
  const jws = await signJws(payload, chain);
  await assertRejects(
    () => verifyAppleJws(jws, { root: chain.root, now: new Date("2100-01-01T00:00:00Z") }),
    JwsVerificationError,
    "not valid",
  );
});

Deno.test("a leaf without Apple's App Store marker extension is rejected", async () => {
  const chain = await createTestChain({ withoutLeafOid: true });
  const jws = await signJws(payload, chain);
  await assertRejects(
    () => verifyAppleJws(jws, { root: chain.root }),
    JwsVerificationError,
    "App Store signing certificate",
  );
});

Deno.test("algorithms other than ES256 and malformed input are rejected", async () => {
  const chain = await createTestChain();
  const none = await signJws(payload, chain, { alg: "none" });
  await assertRejects(() => verifyAppleJws(none, { root: chain.root }), JwsVerificationError);
  await assertRejects(() => verifyAppleJws("a.b", { root: chain.root }), JwsVerificationError);
  await assertRejects(() => verifyAppleJws("", { root: chain.root }), JwsVerificationError);
  const shortChain = await signJws(payload, chain, { x5c: [certBase64(chain.leaf)] });
  await assertRejects(
    () => verifyAppleJws(shortChain, { root: chain.root }),
    JwsVerificationError,
    "three certificates",
  );
});

Deno.test("real Apple root is the default trust anchor (test chain is rejected)", async () => {
  const chain = await createTestChain();
  const jws = await signJws(payload, chain);
  await assertRejects(() => verifyAppleJws(jws), JwsVerificationError, "trusted root");
});
