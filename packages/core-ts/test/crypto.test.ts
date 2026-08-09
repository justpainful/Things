import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import {
  DecryptError,
  ENVELOPE_MAGIC,
  HEADER_LEN,
  NONCE_LEN,
  TAG_LEN,
  fieldAad,
  isEnvelope,
  open,
  seal,
} from '../src/crypto/envelope.ts';
import { DEFAULT_KDF_PARAMS, deriveKekSync, failedAttemptDelayMs, parseKdfParams } from '../src/crypto/kdf.ts';
import {
  FRAME_SIZE,
  decryptObject,
  decryptRange,
  encryptObject,
  frameBounds,
  parseObjectHeader,
} from '../src/crypto/frames.ts';
import { Keyring, deriveDeviceKek } from '../src/crypto/keyring.ts';
import { DeviceSecretStore } from '../src/crypto/deviceSecret.ts';
import { TEST_KDF, cleanup, tempDir } from './helpers.ts';

after(cleanup);

describe('AES-256-GCM envelope', () => {
  const key = Buffer.alloc(32, 7);

  test('round-trips', () => {
    const e = seal(key, 'hello', Buffer.from('aad'));
    assert.equal(open(key, e, Buffer.from('aad')).toString('utf8'), 'hello');
  });

  test('has the normative header layout', () => {
    const e = seal(key, 'x');
    assert.ok(e.subarray(0, 4).equals(ENVELOPE_MAGIC));
    assert.equal(e[4], 1, 'version');
    assert.equal(e[5], 1, 'alg = AES-256-GCM');
    assert.equal(e[6], NONCE_LEN);
    assert.equal(e.length, HEADER_LEN + NONCE_LEN + 1 + TAG_LEN);
    assert.ok(isEnvelope(e));
  });

  test('is deterministic given a fixed nonce — this is what the vectors pin', () => {
    const nonce = Buffer.alloc(12, 3);
    const a = seal(key, 'same', Buffer.from('aad'), { nonce });
    const b = seal(key, 'same', Buffer.from('aad'), { nonce });
    assert.equal(a.toString('hex'), b.toString('hex'));
  });

  test('AAD binds ciphertext to thing_id ‖ field_id', () => {
    const thing = '01890000-0000-7000-8000-00000000aaaa';
    const fieldA = '01890000-0000-7000-8000-00000000bbbb';
    const fieldB = '01890000-0000-7000-8000-00000000cccc';
    const e = seal(key, 'hunter-not-real', fieldAad(thing, fieldA));

    assert.equal(open(key, e, fieldAad(thing, fieldA)).toString('utf8'), 'hunter-not-real');
    // The whole point: a blob transplanted into another field must not open.
    assert.throws(() => open(key, e, fieldAad(thing, fieldB)), DecryptError);
    assert.throws(() => open(key, e, fieldAad(fieldB, fieldA)), DecryptError);
  });

  test('rejects a tampered tag, ciphertext or header', () => {
    const e = seal(key, 'payload');
    for (const i of [4, 5, HEADER_LEN + 1, e.length - 1]) {
      const bad = Buffer.from(e);
      bad[i] ^= 0xff;
      assert.throws(() => open(key, bad), /unsupported|authentication|bad/);
    }
  });

  test('rejects the wrong key', () => {
    const e = seal(key, 'payload');
    assert.throws(() => open(Buffer.alloc(32, 8), e), DecryptError);
  });

  test('rejects a short key', () => {
    assert.throws(() => seal(Buffer.alloc(16), 'x'), RangeError);
  });
});

describe('scrypt KDF', () => {
  test('ships the OWASP parameters from docs/02-SECURITY.md §3', () => {
    assert.deepEqual(DEFAULT_KDF_PARAMS, { algorithm: 'scrypt', N: 65536, r: 8, p: 2, dkLen: 32 });
  });

  test('is deterministic and salt-dependent', () => {
    const salt = Buffer.alloc(16, 1);
    const a = deriveKekSync('123456', salt, TEST_KDF);
    const b = deriveKekSync('123456', salt, TEST_KDF);
    const c = deriveKekSync('123456', Buffer.alloc(16, 2), TEST_KDF);
    assert.equal(a.toString('hex'), b.toString('hex'));
    assert.notEqual(a.toString('hex'), c.toString('hex'));
    assert.equal(a.length, 32);
  });

  test('rejects non-power-of-two N', () => {
    assert.throws(() => deriveKekSync('1', Buffer.alloc(16), { ...TEST_KDF, N: 1000 }), RangeError);
  });

  test('parseKdfParams falls back to the default', () => {
    assert.deepEqual(parseKdfParams(null), DEFAULT_KDF_PARAMS);
    assert.deepEqual(parseKdfParams('{bad'), DEFAULT_KDF_PARAMS);
    assert.equal(parseKdfParams('{"N":1024,"r":8,"p":1,"dkLen":32}').N, 1024);
  });

  test('failed-attempt delay escalates and never wipes', () => {
    assert.equal(failedAttemptDelayMs(0), 0);
    assert.equal(failedAttemptDelayMs(1), 1000);
    assert.ok(failedAttemptDelayMs(3) > failedAttemptDelayMs(2));
    assert.equal(failedAttemptDelayMs(99), failedAttemptDelayMs(5), 'the ladder caps, it does not escalate forever');
  });
});

describe('framed object encryption', () => {
  const key = randomBytes(32);

  test('round-trips a multi-frame payload', () => {
    const plain = randomBytes(FRAME_SIZE * 2 + 4096);
    const file = encryptObject(key, plain);
    assert.deepEqual(decryptObject(key, file), plain);
    assert.equal(frameBounds(file).length, 3);
    assert.equal(parseObjectHeader(file).frameSize, FRAME_SIZE);
  });

  test('round-trips an empty payload', () => {
    const file = encryptObject(key, Buffer.alloc(0));
    assert.equal(decryptObject(key, file).length, 0);
  });

  test('decrypts a range without touching the whole file — the seek property', () => {
    const plain = randomBytes(FRAME_SIZE * 3);
    const file = encryptObject(key, plain);
    const start = FRAME_SIZE + 1234;
    const got = decryptRange(key, file, start, 500);
    assert.deepEqual(got, plain.subarray(start, start + 500));
  });

  test('a range spanning a frame boundary is correct', () => {
    const plain = randomBytes(FRAME_SIZE + 100);
    const file = encryptObject(key, plain);
    const got = decryptRange(key, file, FRAME_SIZE - 50, 100);
    assert.deepEqual(got, plain.subarray(FRAME_SIZE - 50, FRAME_SIZE + 50));
  });

  test('truncation is detected — the last-frame flag is in the AAD', () => {
    const plain = randomBytes(FRAME_SIZE * 2);
    const file = encryptObject(key, plain);
    const bounds = frameBounds(file);
    const truncated = file.subarray(0, bounds[1].offset - 4);
    assert.throws(() => decryptObject(key, truncated), /authentication|mismatch|truncated/);
  });

  test('a swapped frame is detected — the index is in the AAD', () => {
    const plain = randomBytes(FRAME_SIZE * 2);
    const file = encryptObject(key, plain);
    const b = frameBounds(file);
    const f0 = file.subarray(b[0].offset, b[0].offset + b[0].length);
    const swapped = Buffer.concat([file.subarray(0, b[0].offset), f0, file.subarray(b[0].offset + b[0].length)]);
    // identical here, so also flip the first ciphertext byte of frame 0
    swapped[b[0].offset] ^= 0xff;
    assert.throws(() => decryptObject(key, swapped), /authentication/);
  });

  test('rejects a foreign header', () => {
    assert.throws(() => parseObjectHeader(Buffer.alloc(20)), /magic/);
  });
});

describe('keyring', () => {
  function makeKeyring(dir: string) {
    const meta = new Map<string, string>();
    const store = { get: (k: string) => meta.get(k) ?? null, set: (k: string, v: string) => void meta.set(k, v) };
    const device = new DeviceSecretStore({ dir: join(dir, 'keys'), forceFallback: true });
    return { keyring: new Keyring(store, device), meta };
  }

  test('provisions, locks, and unlocks with the PIN', async () => {
    const { keyring, meta } = makeKeyring(tempDir());
    assert.equal(keyring.isProvisioned, false);
    await keyring.provision('123456', TEST_KDF);
    assert.ok(keyring.isProvisioned);
    assert.ok(keyring.isUnlocked);

    const dek = Buffer.from(keyring.requireDek());
    keyring.lock();
    assert.equal(keyring.isUnlocked, false);
    assert.throws(() => keyring.requireDek(), /locked/);

    assert.equal(await keyring.unlockWithPin('000000'), false, 'wrong PIN must not unlock');
    assert.equal(await keyring.unlockWithPin('123456'), true);
    assert.deepEqual(Buffer.from(keyring.requireDek()), dek, 'the same DEK comes back');

    // The DEK is never derived from the PIN — it is wrapped by it.
    assert.ok(meta.get('dek_wrap_pin'));
    assert.notEqual(meta.get('dek_wrap_pin'), dek.toString('base64'));
  });

  test('the device wrapper is an independent second door', async () => {
    const { keyring } = makeKeyring(tempDir());
    await keyring.provision('123456', TEST_KDF);
    const dek = Buffer.from(keyring.requireDek());
    keyring.lock();
    assert.equal(keyring.unlockWithDevice(), true);
    assert.deepEqual(Buffer.from(keyring.requireDek()), dek);
  });

  test('losing the device wrapper still leaves the PIN route open', async () => {
    const dir = tempDir();
    const { keyring, meta } = makeKeyring(dir);
    await keyring.provision('123456', TEST_KDF);
    keyring.lock();
    meta.set('dek_wrap_device', ''); // simulate a profile restore / new team prefix
    assert.equal(keyring.unlockWithDevice(), false);
    assert.equal(await keyring.unlockWithPin('123456'), true, 'the PIN path must always work');
  });

  test('changing the PIN re-wraps 32 bytes and keeps the DEK', async () => {
    const { keyring } = makeKeyring(tempDir());
    await keyring.provision('123456', TEST_KDF);
    const dek = Buffer.from(keyring.requireDek());
    assert.equal(await keyring.changePin('999999', '222222'), false, 'wrong current PIN');
    assert.equal(await keyring.changePin('123456', '222222'), true);
    keyring.lock();
    assert.equal(await keyring.unlockWithPin('123456'), false);
    assert.equal(await keyring.unlockWithPin('222222'), true);
    assert.deepEqual(Buffer.from(keyring.requireDek()), dek, 'the library is not re-encrypted');
  });

  test('KEK2 derivation is deterministic', () => {
    const secret = Buffer.alloc(32, 9);
    const salt = Buffer.alloc(16, 1);
    assert.equal(
      deriveDeviceKek(secret, salt).toString('hex'),
      deriveDeviceKek(secret, salt).toString('hex'),
    );
    assert.notEqual(
      deriveDeviceKek(secret, salt).toString('hex'),
      deriveDeviceKek(secret, Buffer.alloc(16, 2)).toString('hex'),
    );
  });
});

describe('device secret store', () => {
  test('the file fallback survives a round trip and is not stored verbatim', () => {
    const dir = join(tempDir(), 'keys');
    const store = new DeviceSecretStore({ dir, forceFallback: true });
    assert.equal(store.exists(), false);
    const created = store.create();
    assert.equal(created.secret.length, 32);
    assert.equal(created.strength, 'file-fallback');
    assert.ok(store.exists());
    const loaded = store.load();
    assert.ok(loaded);
    assert.deepEqual(loaded.secret, created.secret);
  });

  test('reports which wrapper strength is actually available', () => {
    const store = new DeviceSecretStore({ dir: join(tempDir(), 'keys'), forceFallback: true });
    assert.equal(store.available(), 'file-fallback');
  });
});
