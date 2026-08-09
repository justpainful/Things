import { createServer } from 'node:http';
import type { Server } from 'node:http';
import { randomBytes, createHash } from 'node:crypto';
import type { Core } from '@things/core';
import { LOOPBACK_HOST, SYNC_PORT, assertLoopback } from './net.ts';

/**
 * The sync listener — SCAFFOLD ONLY (M7).
 *
 * What is real here:
 *   · a separate process-level listener on a separate port, as
 *     docs/02-SECURITY.md §7 requires — the web UI's port is never the sync
 *     port, and neither shares an auth surface with the other;
 *   · the pairing handshake *shape*, so both cores can agree on it before
 *     either implements it;
 *   · the oplog read that sync will actually use (`changes since HLC`), which
 *     already exists and is tested.
 *
 * What is deliberately NOT here: the pairing crypto. The spec calls for TLS
 * with a self-signed certificate pinned at pairing time plus a mutual proof of
 * the pairing secret. Half-implementing that would be worse than not having
 * it — it would look finished. Every transfer route answers 501 and says so.
 *
 * It also binds LOOPBACK until that work lands, so an unfinished handshake is
 * not reachable from the LAN in the meantime.
 */

export interface SyncScaffold {
  server: Server;
  port: number;
  pairingCode: string | null;
  close(): Promise<void>;
}

const NOT_IMPLEMENTED = {
  error: 'not_implemented',
  milestone: 'M7',
  detail:
    'LAN sync is not implemented yet. The pairing handshake requires a pinned self-signed certificate ' +
    'and a mutual proof of the pairing secret; shipping half of that would be worse than shipping none.',
};

export function startSyncListener(core: Core, port: number = SYNC_PORT): Promise<SyncScaffold> {
  let pairingCode: string | null = null;
  let pairingExpires = 0;

  const server = createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const json = (status: number, body: unknown) => {
      const buf = Buffer.from(JSON.stringify(body));
      res.writeHead(status, { 'content-type': 'application/json', 'content-length': String(buf.length) });
      res.end(buf);
    };

    // Capability document. Safe to expose: it carries no data and no key.
    if (req.method === 'GET' && url.pathname === '/sync/hello') {
      json(200, {
        product: 'Things',
        protocol: 1,
        status: 'scaffold',
        deviceId: core.deviceId,
        deviceName: core.devices.self()?.name ?? 'This PC',
        platform: 'windows',
        capabilities: ['oplog/v1', 'version-vectors/v1', 'objects/v1'],
        pairing: {
          method: 'out-of-band-qr',
          note: 'Being on the same network grants a device nothing. Pairing is explicit.',
        },
      });
      return;
    }

    // Mint a short-lived pairing code. The PC shows it as a QR; the phone
    // scans it. There is no discovery-based auto-trust.
    if (req.method === 'POST' && url.pathname === '/pair/begin') {
      pairingCode = randomBytes(16).toString('base64url');
      pairingExpires = Date.now() + 120_000;
      json(200, {
        pairingId: createHash('sha256').update(pairingCode).digest('hex').slice(0, 16),
        code: pairingCode,
        expiresAt: new Date(pairingExpires).toISOString(),
        deviceId: core.deviceId,
        next: 'POST /pair/complete with a proof of this code over the pinned TLS channel',
        status: 'scaffold',
      });
      return;
    }

    if (url.pathname === '/pair/complete' || url.pathname.startsWith('/sync/')) {
      json(501, NOT_IMPLEMENTED);
      return;
    }

    json(404, { error: 'not_found' });
  });

  return new Promise((resolve, reject) => {
    server.once('error', reject);
    // Loopback until the pairing crypto exists. See the header comment.
    server.listen({ host: assertLoopback(LOOPBACK_HOST), port }, () => {
      const address = server.address();
      resolve({
        server,
        port: typeof address === 'object' && address ? address.port : port,
        get pairingCode() {
          return Date.now() < pairingExpires ? pairingCode : null;
        },
        close: () => new Promise<void>((done) => server.close(() => done())),
      });
    });
  });
}
