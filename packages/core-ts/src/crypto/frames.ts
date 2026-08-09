import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

/**
 * Framed object encryption — docs/01-DATA-MODEL.md §7.
 *
 * Per-object random 256-bit key, AES-256-GCM, **1 MiB plaintext frames**, so a
 * video can seek without decrypting the whole file. The object's key is
 * wrapped by the DEK and stored in `object.enc_key_wrap`; the 8-byte nonce
 * prefix lives in `object.enc_nonce`.
 *
 * File layout — NORMATIVE:
 *
 *   offset  size  field
 *   ------  ----  ---------------------------------------------------------
 *        0     4  magic 'TOBJ'
 *        4     1  version 0x01
 *        5     1  alg 0x01 = AES-256-GCM
 *        6     4  frame size, big-endian (1048576)
 *       10     8  nonce prefix
 *       18   ...  frames
 *
 *   each frame: 4-byte big-endian ciphertext length, then ciphertext ‖ tag
 *
 * Nonce for frame *i* = noncePrefix (8 bytes) ‖ i (4 bytes, big-endian).
 * Unique per (key, frame) because the key is unique per object.
 *
 * AAD for frame *i* = i (4 bytes BE) ‖ isLast (1 byte). Including "is this the
 * last frame" is what stops a truncation attack: dropping trailing frames would
 * otherwise produce a shorter but perfectly valid file.
 */

export const FRAME_SIZE = 1024 * 1024;
export const OBJ_MAGIC = Buffer.from('TOBJ', 'ascii');
export const OBJ_VERSION = 0x01;
export const OBJ_ALG = 0x01;
export const OBJ_HEADER_LEN = 18;
const TAG_LEN = 16;

export class FrameError extends Error {}

export function newNoncePrefix(): Buffer {
  return randomBytes(8);
}

function frameNonce(prefix: Uint8Array, index: number): Buffer {
  const n = Buffer.alloc(12);
  Buffer.from(prefix).copy(n, 0, 0, 8);
  n.writeUInt32BE(index, 8);
  return n;
}

function frameAad(index: number, isLast: boolean): Buffer {
  const a = Buffer.alloc(5);
  a.writeUInt32BE(index, 0);
  a[4] = isLast ? 1 : 0;
  return a;
}

export function objectHeader(noncePrefix: Uint8Array, frameSize = FRAME_SIZE): Buffer {
  const h = Buffer.alloc(OBJ_HEADER_LEN);
  OBJ_MAGIC.copy(h, 0);
  h[4] = OBJ_VERSION;
  h[5] = OBJ_ALG;
  h.writeUInt32BE(frameSize, 6);
  Buffer.from(noncePrefix).copy(h, 10, 0, 8);
  return h;
}

export function parseObjectHeader(buf: Uint8Array): { frameSize: number; noncePrefix: Buffer } {
  const b = Buffer.from(buf);
  if (b.length < OBJ_HEADER_LEN) throw new FrameError('object header truncated');
  if (!b.subarray(0, 4).equals(OBJ_MAGIC)) throw new FrameError('bad object magic');
  if (b[4] !== OBJ_VERSION) throw new FrameError(`unsupported object version ${b[4]}`);
  if (b[5] !== OBJ_ALG) throw new FrameError(`unsupported object algorithm ${b[5]}`);
  return { frameSize: b.readUInt32BE(6), noncePrefix: b.subarray(10, 18) };
}

export function encryptObject(
  key: Uint8Array,
  plaintext: Uint8Array,
  noncePrefix: Uint8Array = newNoncePrefix(),
  frameSize = FRAME_SIZE,
): Buffer {
  if (key.length !== 32) throw new RangeError('object key must be 32 bytes');
  const pt = Buffer.from(plaintext);
  const frames = Math.max(1, Math.ceil(pt.length / frameSize));
  const parts: Buffer[] = [objectHeader(noncePrefix, frameSize)];

  for (let i = 0; i < frames; i++) {
    const slice = pt.subarray(i * frameSize, Math.min((i + 1) * frameSize, pt.length));
    const cipher = createCipheriv('aes-256-gcm', Buffer.from(key), frameNonce(noncePrefix, i));
    cipher.setAAD(frameAad(i, i === frames - 1));
    const ct = Buffer.concat([cipher.update(slice), cipher.final(), cipher.getAuthTag()]);
    const len = Buffer.alloc(4);
    len.writeUInt32BE(ct.length, 0);
    parts.push(len, ct);
  }
  return Buffer.concat(parts);
}

export function decryptObject(key: Uint8Array, file: Uint8Array): Buffer {
  const b = Buffer.from(file);
  const { frameSize, noncePrefix } = parseObjectHeader(b);
  void frameSize;
  const out: Buffer[] = [];
  let off = OBJ_HEADER_LEN;
  let i = 0;
  const bounds = frameBounds(b);
  while (off < b.length) {
    if (off + 4 > b.length) throw new FrameError('frame length truncated');
    const len = b.readUInt32BE(off);
    off += 4;
    if (off + len > b.length) throw new FrameError('frame truncated');
    out.push(decryptFrame(key, noncePrefix, b.subarray(off, off + len), i, i === bounds.length - 1));
    off += len;
    i++;
  }
  if (i !== bounds.length) throw new FrameError('frame count mismatch');
  return Buffer.concat(out);
}

function decryptFrame(
  key: Uint8Array,
  noncePrefix: Uint8Array,
  frame: Buffer,
  index: number,
  isLast: boolean,
): Buffer {
  if (frame.length < TAG_LEN) throw new FrameError('frame shorter than its tag');
  const ct = frame.subarray(0, frame.length - TAG_LEN);
  const tag = frame.subarray(frame.length - TAG_LEN);
  const d = createDecipheriv('aes-256-gcm', Buffer.from(key), frameNonce(noncePrefix, index));
  d.setAAD(frameAad(index, isLast));
  d.setAuthTag(tag);
  try {
    return Buffer.concat([d.update(ct), d.final()]);
  } catch {
    throw new FrameError(`frame ${index} failed authentication`);
  }
}

/** Byte offsets of every frame in the file — the index that makes seeking cheap. */
export function frameBounds(file: Uint8Array): { offset: number; length: number }[] {
  const b = Buffer.from(file);
  parseObjectHeader(b);
  const out: { offset: number; length: number }[] = [];
  let off = OBJ_HEADER_LEN;
  while (off < b.length) {
    if (off + 4 > b.length) throw new FrameError('frame length truncated');
    const len = b.readUInt32BE(off);
    out.push({ offset: off + 4, length: len });
    off += 4 + len;
  }
  return out;
}

/**
 * Decrypt only the plaintext byte range [start, start+length) — the property
 * framing exists for. Touches ceil(length / FRAME_SIZE) + 1 frames, not the file.
 */
export function decryptRange(
  key: Uint8Array,
  file: Uint8Array,
  start: number,
  length: number,
): Buffer {
  const b = Buffer.from(file);
  const { frameSize, noncePrefix } = parseObjectHeader(b);
  const bounds = frameBounds(b);
  const first = Math.floor(start / frameSize);
  const last = Math.min(bounds.length - 1, Math.floor((start + Math.max(0, length) - 1) / frameSize));
  const chunks: Buffer[] = [];
  for (let i = first; i <= last && i < bounds.length; i++) {
    const f = bounds[i];
    chunks.push(
      decryptFrame(key, noncePrefix, b.subarray(f.offset, f.offset + f.length), i, i === bounds.length - 1),
    );
  }
  const joined = Buffer.concat(chunks);
  const localStart = start - first * frameSize;
  return joined.subarray(localStart, localStart + length);
}
