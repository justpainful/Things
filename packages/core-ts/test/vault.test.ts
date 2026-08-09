import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { Core } from '../src/core.ts';
import { FileVault, MemoryVault, MirroredVault, migrateVaultFromMeta } from '../src/crypto/vault.ts';
import { canonicalJson } from '../src/canonicalJson.ts';
import { TEST_KDF, cleanup, tempDir } from './helpers.ts';

after(cleanup);

/**
 * `vault.json` — spec/crypto.md §3.
 *
 * The wrapped DEK cannot live in the `meta` table. Reading `meta` requires
 * opening the database, opening the database requires the DEK, and getting the
 * DEK requires reading `meta`. These tests are what stops that circle being
 * re-introduced by someone who only sees an unencrypted SQLite file and
 * reasonably concludes that `meta` is fine.
 */

async function provisionedCore(dir: string): Promise<Core> {
  const core = Core.open({ dataDir: dir, deviceName: 'TEST-PC', forceFallbackDeviceSecret: true });
  await core.keyring.provision('123456', TEST_KDF);
  return core;
}

describe('vault.json sidecar', () => {
  test('provisioning writes the wrappers to the sidecar, not only to the database', async () => {
    const dir = tempDir();
    const core = await provisionedCore(dir);
    const path = join(dir, 'vault.json');
    assert.ok(existsSync(path), 'vault.json must exist beside things.sqlite');

    const contents = JSON.parse(readFileSync(path, 'utf8')) as Record<string, unknown>;
    for (const key of ['kdf_salt', 'kdf_params', 'dek_wrap_pin', 'dek_check']) {
      assert.equal(typeof contents[key], 'string', `${key} must be a string in vault.json`);
    }
    for (const value of Object.values(contents)) {
      assert.equal(typeof value, 'string', 'vault.json holds string values only — no nesting, no numbers');
    }
    core.close();
  });

  test('the file is canonical bytes: sorted keys, no whitespace, no trailing newline', async () => {
    const dir = tempDir();
    const core = await provisionedCore(dir);
    const raw = readFileSync(join(dir, 'vault.json'), 'utf8');
    // core-swift's FileVaultStorage writes `JSONValue.object(…).canonicalJSON`
    // and nothing else. Byte parity means a file touched by the phone and then
    // by the PC produces no spurious diff.
    assert.equal(raw, canonicalJson(JSON.parse(raw) as Record<string, string>));
    assert.ok(!raw.endsWith('\n'));
    core.close();
  });

  test('unlocking never reads meta — the whole point of the sidecar', async () => {
    const dir = tempDir();
    const core = await provisionedCore(dir);
    core.close();

    // Wipe every trace from the database. If unlock still works, `meta` was
    // genuinely not load-bearing; if it does not, the circular dependency is
    // back.
    const reopened = Core.open({ dataDir: dir, deviceName: 'TEST-PC', forceFallbackDeviceSecret: true });
    reopened.db.run("DELETE FROM meta WHERE key LIKE 'dek_%' OR key LIKE 'kdf_%'");
    assert.equal(reopened.db.meta('dek_wrap_pin'), null);
    assert.equal(await reopened.keyring.unlockWithPin('123456'), true);
    reopened.close();
  });

  test('unknown keys survive a rewrite — two cores and two versions share this file', () => {
    const vault = new FileVault(join(tempDir(), 'vault.json'));
    vault.set('dek_wrap_pin', 'AAAA');
    vault.set('written_by_a_newer_ios_build', 'keep me');
    vault.set('kdf_salt', 'BBBB');
    vault.set('dek_wrap_pin', 'CCCC');
    assert.equal(vault.get('written_by_a_newer_ios_build'), 'keep me');
    assert.equal(vault.get('dek_wrap_pin'), 'CCCC');
  });

  test('an absent device wrapper is spelled by omission, not by an empty string', async () => {
    const dir = tempDir();
    const core = await provisionedCore(dir);
    core.vault.set('dek_wrap_device', null);
    assert.ok(!('dek_wrap_device' in core.vault.read()));
    assert.equal(core.keyring.deviceWrapperStrength(), 'none');
    // The PIN route is the recovery path and must be untouched by any of this.
    core.keyring.lock();
    assert.equal(await core.keyring.unlockWithPin('123456'), true);
    core.close();
  });

  test('the four mirrored keys still land in meta, for a self-describing backup', async () => {
    const dir = tempDir();
    const core = await provisionedCore(dir);
    assert.equal(core.db.meta('dek_wrap_pin'), core.vault.get('dek_wrap_pin'));
    assert.equal(core.db.meta('kdf_salt'), core.vault.get('kdf_salt'));
    core.close();
  });
});

describe('vault.json migration from the meta table', () => {
  test('a library created by the old code is lifted into the sidecar and still opens', async () => {
    const dir = tempDir();
    const core = await provisionedCore(dir);
    const legacy = core.vault.read();
    core.close();

    // Rewind to what the previous code produced: everything in `meta`, no
    // sidecar at all. A developer's local library looks exactly like this.
    const rewind = Core.open({ dataDir: dir, deviceName: 'TEST-PC', forceFallbackDeviceSecret: true });
    for (const [k, v] of Object.entries(legacy)) rewind.db.setMeta(k, v);
    rewind.close();
    rmSync(join(dir, 'vault.json'));

    const migrated = Core.open({ dataDir: dir, deviceName: 'TEST-PC', forceFallbackDeviceSecret: true });
    assert.ok(migrated.vaultMigration.migrated, 'the migration must report that it ran');
    assert.ok(migrated.vaultMigration.keys.includes('dek_wrap_pin'));
    assert.ok(existsSync(join(dir, 'vault.json')));
    assert.equal(await migrated.keyring.unlockWithPin('123456'), true, 'local data must not be stranded');
    migrated.close();
  });

  test('the migration never overwrites a sidecar that already has a PIN wrapper', () => {
    const meta = new MemoryVault();
    meta.set('dek_wrap_pin', 'from-meta');
    meta.set('kdf_salt', 'meta-salt');
    const vault = new MemoryVault();
    vault.set('dek_wrap_pin', 'from-vault');

    const result = migrateVaultFromMeta(meta, vault);
    assert.equal(result.migrated, false);
    assert.equal(vault.get('dek_wrap_pin'), 'from-vault');
    assert.equal(vault.get('kdf_salt'), null);
  });

  test("the old code's empty-string device wrapper does not migrate as a value", () => {
    const meta = new MemoryVault();
    meta.set('dek_wrap_pin', 'wrap');
    meta.set('kdf_salt', 'salt');
    meta.set('dek_wrap_device', '');
    const vault = new MemoryVault();

    migrateVaultFromMeta(meta, vault);
    assert.equal(vault.get('dek_wrap_device'), null, "'' meant 'no device wrapper'; the sidecar spells that as absent");
  });

  test('a mirror that throws does not take the sidecar write down with it', () => {
    const vault = new MemoryVault();
    const brokenMirror = {
      get: () => null,
      set: () => {
        throw new Error('database is locked');
      },
    };
    const store = new MirroredVault(vault, brokenMirror);
    store.set('dek_wrap_pin', 'wrap');
    assert.equal(store.get('dek_wrap_pin'), 'wrap');
  });
});
