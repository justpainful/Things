import { createCipheriv, createDecipheriv, randomBytes, timingSafeEqual } from 'node:crypto';

/**
 * AES-256-GCM envelope — NORMATIVE byte layout.
 * Mirrored by `spec/vectors/crypto-envelope.json`; the Swift core must produce
 * byte-identical output for the same inputs.
 *
 *   offset  size  field
 *   ------  ----  ---------------------------------------------------------
 *        0     4  magic   'TENV'  (0x54 0x45 0x4e 0x56)
 *        4     1  version 0x01
 *        5     1  alg     0x01 = AES-256-GCM, 12-byte nonce, 16-byte tag
 *        6     1  nonceLen (12)
 *        7    12  nonce
 *       19     N  ciphertext
 *   19 + N    16  auth tag
 *
 * The header bytes 0..6 are themselves fed to GCM as additional authenticated
 * data, prepended to the caller's AAD. So a version/algorithm downgrade cannot
 * be forged by editing the header.
 */

export const ENVELOPE_MAGIC = Buffer.from('TENV', 'ascii');
export const ENVELOPE_VERSION = 0x01;
export const ALG_AES_256_GCM = 0x01;
export const NONCE_LEN = 12;
export const TAG_LEN = 16;
export const HEADER_LEN = 7;

export class DecryptError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DecryptError';
  }
}

/**
 * AAD for a secret field: `thing_id ‖ field_id` — docs/01-DATA-MODEL.md §7.
 *
 * Both halves are fixed-length UUID strings (36 chars), so plain concatenation
 * is unambiguous and no separator is needed. Binding the ciphertext to its
 * location is what stops a blob being transplanted into a different Thing to
 * trick the app into decrypting it somewhere it does not belong.
 */
export function fieldAad(thingId: string, fieldId: string): Buffer {
  return Buffer.from(`${thingId}${fieldId}`, 'utf8');
}

function header(): Buffer {
  const h = Buffer.alloc(HEADER_LEN);
  ENVELOPE_MAGIC.copy(h, 0);
  h[4] = ENVELOPE_VERSION;
  h[5] = ALG_AES_256_GCM;
  h[6] = NONCE_LEN;
  return h;
}

export interface SealOptions {
  /** Deterministic nonce — TESTS AND CONFORMANCE VECTORS ONLY. Never in production. */
  nonce?: Uint8Array;
}

export function seal(
  key: Uint8Array,
  plaintext: Uint8Array | string,
  aad: Uint8Array = Buffer.alloc(0),
  opts: SealOptions = {},
): Buffer {
  if (key.length !== 32) throw new RangeError('AES-256-GCM requires a 32-byte key');
  const nonce = opts.nonce ? Buffer.from(opts.nonce) : randomBytes(NONCE_LEN);
  if (nonce.length !== NONCE_LEN) throw new RangeError(`nonce must be ${NONCE_LEN} bytes`);

  const h = header();
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  cipher.setAAD(Buffer.concat([h, Buffer.from(aad)]));
  const pt = typeof plaintext === 'string' ? Buffer.from(plaintext, 'utf8') : Buffer.from(plaintext);
  const ct = Buffer.concat([cipher.update(pt), cipher.final()]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([h, nonce, ct, tag]);
}

export function open(
  key: Uint8Array,
  envelope: Uint8Array,
  aad: Uint8Array = Buffer.alloc(0),
): Buffer {
  const buf = Buffer.from(envelope);
  if (buf.length < HEADER_LEN + NONCE_LEN + TAG_LEN) throw new DecryptError('envelope too short');
  if (!timingSafeEqual(buf.subarray(0, 4), ENVELOPE_MAGIC)) throw new DecryptError('bad magic');
  if (buf[4] !== ENVELOPE_VERSION) throw new DecryptError(`unsupported envelope version ${buf[4]}`);
  if (buf[5] !== ALG_AES_256_GCM) throw new DecryptError(`unsupported algorithm ${buf[5]}`);
  if (buf[6] !== NONCE_LEN) throw new DecryptError('bad nonce length');

  const h = buf.subarray(0, HEADER_LEN);
  const nonce = buf.subarray(HEADER_LEN, HEADER_LEN + NONCE_LEN);
  const tag = buf.subarray(buf.length - TAG_LEN);
  const ct = buf.subarray(HEADER_LEN + NONCE_LEN, buf.length - TAG_LEN);

  const decipher = createDecipheriv('aes-256-gcm', key, nonce);
  decipher.setAAD(Buffer.concat([h, Buffer.from(aad)]));
  decipher.setAuthTag(tag);
  try {
    return Buffer.concat([decipher.update(ct), decipher.final()]);
  } catch {
    // Wrong key, tampered ciphertext, or — the case this design exists for —
    // an envelope lifted from a different thing_id/field_id.
    throw new DecryptError('authentication failed');
  }
}

export function openUtf8(key: Uint8Array, envelope: Uint8Array, aad?: Uint8Array): string {
  return open(key, envelope, aad).toString('utf8');
}

export function isEnvelope(buf: Uint8Array | null | undefined): boolean {
  return !!buf && buf.length >= HEADER_LEN && Buffer.from(buf.subarray(0, 4)).equals(ENVELOPE_MAGIC);
}
