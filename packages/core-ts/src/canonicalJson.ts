/**
 * Canonical JSON — `spec/oplog.md` §2. NORMATIVE.
 *
 * `attrs_json`, `prev_json`, `version_vector`, `icon_json` and `kdf_params` are
 * compared, hashed and diffed across two independently written cores. They
 * therefore have exactly one serialisation:
 *
 *  1. object keys sorted ascending;
 *  2. no insignificant whitespace;
 *  3. strings escaped minimally — `\"`, `\\`, `\n`, `\r`, `\t`, and `\u00XX`
 *     for every other codepoint below 0x20;
 *  4. integers with no decimal point and no exponent; non-integers use the
 *     shortest representation that round-trips;
 *  5. `null` is a value and is preserved — absent and null mean different
 *     things in an attribute map.
 *
 * `JSON.stringify` is NOT good enough, and the reason is rule 3: it emits `\b`
 * for 0x08 and `\f` for 0x0c, while `core-swift` writes `` / ``.
 * A field label containing a form feed would produce two different `attrs_json`
 * byte strings for the same change — which is the entire class of bug this
 * module exists to remove. Everything else about `JSON.stringify` happens to
 * agree; that one does not, and "happens to agree" is not a contract.
 *
 * Key order note: keys in this project are ASCII (column names, device UUIDs),
 * where JavaScript's default sort and Swift's `String` sort are the same order.
 * `spec/oplog.md` §2 puts anything else out of contract.
 */

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

/** Serialise a value to the one canonical form both cores must produce. */
export function canonicalJson(value: unknown): string {
  const out: string[] = [];
  write(value, out);
  return out.join('');
}

function write(value: unknown, out: string[]): void {
  if (value === null || value === undefined) {
    out.push('null');
    return;
  }
  switch (typeof value) {
    case 'boolean':
      out.push(value ? 'true' : 'false');
      return;
    case 'number':
      out.push(writeNumber(value));
      return;
    case 'bigint':
      out.push(value.toString());
      return;
    case 'string':
      writeString(value, out);
      return;
    default:
      break;
  }
  if (Array.isArray(value)) {
    out.push('[');
    for (let i = 0; i < value.length; i++) {
      if (i > 0) out.push(',');
      write(value[i], out);
    }
    out.push(']');
    return;
  }
  const obj = value as Record<string, unknown>;
  const keys = Object.keys(obj).sort();
  out.push('{');
  let first = true;
  for (const key of keys) {
    // `undefined` is not a JSON value; treat it as absent, exactly as
    // JSON.stringify does, so a partially-built attrs map behaves predictably.
    if (obj[key] === undefined) continue;
    if (!first) out.push(',');
    first = false;
    writeString(key, out);
    out.push(':');
    write(obj[key], out);
  }
  out.push('}');
}

function writeNumber(value: number): string {
  if (!Number.isFinite(value)) {
    throw new TypeError(`canonical JSON cannot represent ${value}`);
  }
  // `Number#toString` is the shortest round-tripping form, and it already emits
  // an integral value without a decimal point: 3.0 → "3", 2.5 → "2.5".
  return String(value);
}

function writeString(text: string, out: string[]): void {
  out.push('"');
  for (const char of text) {
    switch (char) {
      case '"':
        out.push('\\"');
        continue;
      case '\\':
        out.push('\\\\');
        continue;
      case '\n':
        out.push('\\n');
        continue;
      case '\r':
        out.push('\\r');
        continue;
      case '\t':
        out.push('\\t');
        continue;
      default:
        break;
    }
    const code = char.codePointAt(0)!;
    if (code < 0x20) {
      out.push(`\\u${code.toString(16).padStart(4, '0')}`);
    } else {
      // Everything else is literal UTF-8 — no \u escaping of non-ASCII.
      out.push(char);
    }
  }
  out.push('"');
}
