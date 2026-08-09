import { test, describe, after } from 'node:test';
import assert from 'node:assert/strict';
import { connect } from 'node:net';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startServer } from '../src/server.ts';
import {
  LOOPBACK_HOST,
  NetworkBoundaryError,
  assertLoopback,
  isAllowedHostHeader,
  isLoopbackHost,
  lanAddresses,
} from '../src/net.ts';

/**
 * The network boundary — docs/02-SECURITY.md §7.
 *
 * "The web UI binds 127.0.0.1 only, port 6767. It is never reachable from the
 * LAN. This is enforced in code, not configuration, **and covered by a test**."
 *
 * This is that test. It does not check a setting; it opens real TCP sockets to
 * every non-internal address this machine has and requires every one to fail.
 */

const dirs: string[] = [];
function dataDir(): string {
  const d = mkdtempSync(join(tmpdir(), 'things-srv-'));
  dirs.push(d);
  return d;
}
after(() => {
  for (const d of dirs) {
    try {
      rmSync(d, { recursive: true, force: true });
    } catch {
      /* sqlite handle */
    }
  }
});

function tryConnect(host: string, port: number, timeoutMs = 1500): Promise<'connected' | 'refused'> {
  return new Promise((resolve) => {
    const socket = connect({ host, port });
    const done = (r: 'connected' | 'refused') => {
      socket.destroy();
      resolve(r);
    };
    socket.setTimeout(timeoutMs);
    socket.once('connect', () => done('connected'));
    socket.once('error', () => done('refused'));
    socket.once('timeout', () => done('refused'));
  });
}

function rawRequest(port: number, request: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const socket = connect({ host: '127.0.0.1', port }, () => socket.write(request));
    let out = '';
    socket.setEncoding('utf8');
    socket.on('data', (d) => (out += d));
    socket.on('end', () => resolve(out));
    socket.on('error', reject);
  });
}

describe('the loopback boundary is code, not configuration', () => {
  test('assertLoopback rejects every non-loopback host', () => {
    for (const good of ['127.0.0.1', 'localhost', '::1', ' 127.0.0.1 ', 'LOCALHOST']) {
      assert.equal(isLoopbackHost(good), true, good);
      assert.doesNotThrow(() => assertLoopback(good));
    }
    for (const bad of ['0.0.0.0', '::', '192.168.1.10', '10.0.0.5', 'example.invalid', '', undefined, null]) {
      assert.equal(isLoopbackHost(bad as string), false, String(bad));
      assert.throws(() => assertLoopback(bad as string), NetworkBoundaryError, String(bad));
    }
  });

  test('undefined — which node:net reads as ALL interfaces — is rejected', () => {
    assert.throws(() => assertLoopback(undefined), NetworkBoundaryError);
  });

  test('the Host header guard blocks DNS rebinding', () => {
    assert.equal(isAllowedHostHeader('localhost:6767'), true);
    assert.equal(isAllowedHostHeader('127.0.0.1:6767'), true);
    assert.equal(isAllowedHostHeader('[::1]:6767'), true);
    assert.equal(isAllowedHostHeader('evil.example:6767'), false);
    assert.equal(isAllowedHostHeader('192.168.1.10:6767'), false);
    assert.equal(isAllowedHostHeader(undefined), false);
  });

  test('a running server answers on loopback and on NO LAN interface', async (t) => {
    const s = await startServer({
      port: 0,
      startSync: false,
      forceFallbackDeviceSecret: true,
      config: { dataDir: dataDir(), autoLockMs: 0 },
    });

    try {
      assert.equal(await tryConnect(LOOPBACK_HOST, s.port), 'connected', 'loopback must answer');

      const lan = lanAddresses();
      if (lan.length === 0) {
        t.diagnostic('no non-internal IPv4 interfaces on this machine; the LAN probe is vacuous here');
      }
      for (const addr of lan) {
        assert.equal(
          await tryConnect(addr, s.port),
          'refused',
          `the service must not be reachable on LAN address ${addr}`,
        );
      }

      // And the same check against the real port, in case anything else bound it.
      const res = await fetch(`http://127.0.0.1:${s.port}/api/state`);
      assert.equal(res.status, 200);
      const state = (await res.json()) as { provisioned: boolean };
      assert.equal(typeof state.provisioned, 'boolean');
    } finally {
      await s.close();
    }
  });

  test('a request with a foreign Host header is refused', async () => {
    const s = await startServer({
      port: 0,
      startSync: false,
      forceFallbackDeviceSecret: true,
      config: { dataDir: dataDir(), autoLockMs: 0 },
    });
    try {
      // fetch() will not let us forge Host — it is a forbidden header name —
      // so this speaks HTTP/1.1 down a raw socket, which is what an attacker
      // would be doing anyway.
      const good = await rawRequest(s.port, 'GET /api/state HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n');
      assert.match(good, /^HTTP\/1\.1 200/);

      const bad = await rawRequest(
        s.port,
        'GET /api/state HTTP/1.1\r\nHost: attacker.example\r\nConnection: close\r\n\r\n',
      );
      assert.match(bad, /^HTTP\/1\.1 403/);
      assert.match(bad, /localhost/);
    } finally {
      await s.close();
    }
  });

  test('the sync listener is a SEPARATE port and refuses to transfer anything yet', async () => {
    const s = await startServer({
      port: 0,
      startSync: true,
      syncPort: 0,
      forceFallbackDeviceSecret: true,
      config: { dataDir: dataDir(), autoLockMs: 0 },
    });
    try {
      assert.ok(s.sync);
      assert.notEqual(s.sync.port, s.port, 'sync must not share the web port');

      const hello = await fetch(`http://127.0.0.1:${s.sync.port}/sync/hello`);
      assert.equal(hello.status, 200);
      const doc = (await hello.json()) as { protocol: number; status: string };
      assert.equal(doc.protocol, 1);
      assert.equal(doc.status, 'scaffold');

      const transfer = await fetch(`http://127.0.0.1:${s.sync.port}/sync/changes`);
      assert.equal(transfer.status, 501, 'sync transfer must not pretend to work');
    } finally {
      await s.close();
    }
  });
});
