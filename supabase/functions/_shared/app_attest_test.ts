import { assert, assertEquals, assertRejects, assertThrows } from "./test_deps.ts";
import {
  type AppAttestConfig,
  ATTEST_ASSERTION_HEADER,
  ATTEST_KEY_HEADER,
  AttestationError,
  checkRequestAttestation,
  derSignatureToRaw,
  handleAppAttest,
  verifyAssertion,
  verifyAttestation,
  withAttestStatus,
} from "./app_attest.ts";
import { appAttestRootCertificate } from "./app_attest_root_ca.ts";
import { CborError, decodeCbor } from "./cbor.ts";
import { HttpError } from "./http.ts";
import {
  createAttestCA,
  encodeCbor,
  FakeDevice,
  MemoryAttestRegistry,
  rawSignatureToDer,
} from "./testing/app_attest_fixtures.ts";

const appId = "ABCDE12345.app.dayledger";
const config: AppAttestConfig = { appId, mode: "enforce", allowDevelopment: false };
const encoder = new TextEncoder();

async function setup() {
  const ca = await createAttestCA();
  const device = await FakeDevice.create(appId, ca);
  return { ca, device, options: { root: ca.root } };
}

async function registered() {
  const { ca, device, options } = await setup();
  const registry = new MemoryAttestRegistry();
  const { challenge } = await handleAppAttest({ action: "challenge" }, config, registry, options);
  await handleAppAttest(
    {
      action: "register",
      keyId: device.keyId,
      attestation: await device.attest(challenge as string),
      challenge,
    },
    config,
    registry,
    options,
  );
  return { ca, device, registry };
}

function request(headers: Record<string, string> = {}): Request {
  return new Request("https://x/functions/v1/ai-suggest", { method: "POST", headers });
}

Deno.test("the bundled Apple App Attestation root matches its pinned fingerprint", async () => {
  const root = await appAttestRootCertificate();
  assertEquals(root.subject, "CN=Apple App Attestation Root CA, O=Apple Inc., ST=California");
});

Deno.test("a genuine attestation registers the key with counter 0", async () => {
  const { device, options } = await setup();
  const key = await verifyAttestation(
    { keyId: device.keyId, attestation: await device.attest("c1"), challenge: "c1" },
    config,
    options,
  );
  assertEquals(key.keyId, device.keyId);
  assertEquals(key.counter, 0);
  assertEquals(key.environment, "production");
});

Deno.test("attestations that aren't genuine, current or ours are rejected", async () => {
  const { device, options } = await setup();
  const otherCA = await createAttestCA();
  const other = await FakeDevice.create(appId, otherCA);
  const attempt =
    (attestation: Promise<string>, keyId = device.keyId, challenge = "c") => async () =>
      verifyAttestation({ keyId, attestation: await attestation, challenge }, config, options);
  const cases: [string, () => Promise<unknown>][] = [
    ["untrusted CA", attempt(device.attest("c", { signer: otherCA }))],
    ["other challenge", attempt(device.attest("c"), device.keyId, "d")],
    ["wrong nonce", attempt(device.attest("c", { wrongNonce: true }))],
    ["other app", attempt(device.attest("c", { appId: "ZZZZZ99999.other" }))],
    ["development key", attempt(device.attest("c", { environment: "development" }))],
    ["non-zero counter", attempt(device.attest("c", { counter: 3 }))],
    ["key ID of another key", attempt(device.attest("c"), other.keyId)],
    ["garbage", attempt(Promise.resolve("AAAA"))],
  ];
  for (const [name, run] of cases) {
    const error = await run().then(() => undefined, (e) => e);
    assert(error instanceof AttestationError, `${name}: ${error}`);
  }
});

Deno.test("development keys are accepted only when allowed", async () => {
  const { device, options } = await setup();
  const key = await verifyAttestation(
    {
      keyId: device.keyId,
      attestation: await device.attest("c", { environment: "development" }),
      challenge: "c",
    },
    { ...config, allowDevelopment: true },
    options,
  );
  assertEquals(key.environment, "development");
});

Deno.test("challenges are one-use and expire", async () => {
  const { device, options } = await setup();
  let now = new Date("2026-11-21T10:00:00Z");
  const registry = new MemoryAttestRegistry(() => now);
  const { challenge } = await handleAppAttest({ action: "challenge" }, config, registry, {
    ...options,
    now,
  });
  const body = {
    action: "register",
    keyId: device.keyId,
    attestation: await device.attest(challenge as string),
    challenge,
  };
  now = new Date("2026-11-21T10:06:00Z");
  const expired = await assertRejects(
    () => handleAppAttest(body, config, registry, options),
    HttpError,
  );
  assertEquals(expired.code, "invalid_challenge");

  const fresh = new MemoryAttestRegistry();
  const second = await handleAppAttest({ action: "challenge" }, config, fresh, options);
  const ok = {
    ...body,
    challenge: second.challenge,
    attestation: await device.attest(second.challenge as string),
  };
  assertEquals(await handleAppAttest(ok, config, fresh, options), { registered: true });
  const reused = await assertRejects(() => handleAppAttest(ok, config, fresh, options), HttpError);
  assertEquals(reused.code, "invalid_challenge");
});

Deno.test("assertions are bound to the body and their counter must increase", async () => {
  const { device, registry } = await registered();
  const key = (await registry.getKey(device.keyId))!;
  const body = encoder.encode('{"summary":{}}');

  assertEquals(
    await verifyAssertion(
      { assertion: await device.assert(body, 1), clientData: body },
      key,
      appId,
    ),
    1,
  );
  await assertRejects(
    async () =>
      verifyAssertion(
        {
          assertion: await device.assert(body, 1),
          clientData: encoder.encode('{"summary":{"x":1}}'),
        },
        key,
        appId,
      ),
    AttestationError,
    "signature",
  );
  await assertRejects(
    async () =>
      verifyAssertion({ assertion: await device.assert(body, 0), clientData: body }, key, appId),
    AttestationError,
    "counter",
  );
  await assertRejects(
    async () =>
      verifyAssertion(
        { assertion: await device.assert(body, 2, "ZZZZZ99999.other"), clientData: body },
        key,
        appId,
      ),
    AttestationError,
    "another app",
  );
});

Deno.test("enforce mode admits only verified, fresh requests", async () => {
  const { device, registry } = await registered();
  const body = encoder.encode('{"grant_type":"refresh_token","refresh_token":"r"}');
  const assertion = await device.assert(body, 1);
  const headers = { [ATTEST_KEY_HEADER]: device.keyId, [ATTEST_ASSERTION_HEADER]: assertion };
  const silent = () => {};

  assertEquals(
    await checkRequestAttestation(request(headers), body, config, registry, silent),
    "verified",
  );
  const replay = await assertRejects(
    () => checkRequestAttestation(request(headers), body, config, registry, silent),
    HttpError,
  );
  assertEquals([replay.status, replay.code], [401, "attestation_invalid"]);

  const missing = await assertRejects(
    () => checkRequestAttestation(request(), body, config, registry, silent),
    HttpError,
  );
  assertEquals(missing.code, "attestation_required");

  const stranger = await FakeDevice.create(appId, await createAttestCA());
  const unknown = await assertRejects(
    async () =>
      checkRequestAttestation(
        request({
          [ATTEST_KEY_HEADER]: stranger.keyId,
          [ATTEST_ASSERTION_HEADER]: await stranger.assert(body, 1),
        }),
        body,
        config,
        registry,
        silent,
      ),
    HttpError,
  );
  assertEquals(unknown.code, "attest_key_unknown");
});

Deno.test("report mode logs but never blocks; off mode does nothing", async () => {
  const { registry } = await registered();
  const logged: string[] = [];
  const report = { ...config, mode: "report" as const };
  const outcome = await checkRequestAttestation(
    request(),
    new Uint8Array(),
    report,
    registry,
    (m) => logged.push(m),
  );
  assertEquals(outcome, "missing");
  assertEquals(logged.length, 1);
  const bad = request({ [ATTEST_KEY_HEADER]: "nope", [ATTEST_ASSERTION_HEADER]: "AAAA" });
  assertEquals(
    await checkRequestAttestation(bad, new Uint8Array(), report, registry, () => {}),
    "unknown_key",
  );
  assertEquals(
    await checkRequestAttestation(
      request(),
      new Uint8Array(),
      { ...config, mode: "off" },
      registry,
    ),
    "disabled",
  );
  const disabled = await assertRejects(
    () => handleAppAttest({ action: "challenge" }, { ...config, mode: "off" }, registry),
    HttpError,
  );
  assertEquals(disabled.status, 503);
});

Deno.test("CBOR and DER parsing reject malformed input", () => {
  assertEquals(
    decodeCbor(encodeCbor({ a: [1, "b", new Uint8Array([7])] })),
    new Map<unknown, unknown>([["a", [1, "b", new Uint8Array([7])]]]) as never,
  );
  assertThrows(() => decodeCbor(new Uint8Array([0x5a, 0xff, 0xff, 0xff, 0xff])), CborError);
  assertThrows(() => decodeCbor(new Uint8Array([0x01, 0x02])), CborError, "Trailing");
  assertThrows(() => decodeCbor(new Uint8Array([0xf9, 0, 0])), CborError);

  const raw = new Uint8Array(64).map((_, i) => (i === 0 || i === 32 ? 0x80 : i));
  assertEquals(derSignatureToRaw(rawSignatureToDer(raw)), raw);
  const leadingZero = new Uint8Array(64).map((_, i) => (i < 3 ? 0 : i));
  assertEquals(derSignatureToRaw(rawSignatureToDer(leadingZero)), leadingZero);
  assertThrows(() => derSignatureToRaw(new Uint8Array([0x30, 0x02, 0x05, 0x00])), AttestationError);
});
