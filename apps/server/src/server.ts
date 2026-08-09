import { createServer } from 'node:http';
import type { Server } from 'node:http';
import { Core } from '@things/core';
import { LOOPBACK_HOST, WEB_PORT, assertLoopback, isAllowedHostHeader } from './net.ts';
import { HttpError, makeCtx } from './router.ts';
import { PUBLIC_ROUTES, buildApi } from './api.ts';
import { Session } from './session.ts';
import { loadConfig } from './config.ts';
import type { ServerConfig } from './config.ts';
import { missingBuildPage, serveStatic } from './static.ts';
import { startSyncListener } from './sync.ts';
import type { SyncScaffold } from './sync.ts';

export interface ThingsServer {
  server: Server;
  core: Core;
  session: Session;
  config: ServerConfig;
  port: number;
  sync: SyncScaffold | null;
  close(): Promise<void>;
}

export interface StartOptions {
  /** Test-only: 0 asks the OS for a free loopback port. Never a host. */
  port?: number;
  config?: Partial<ServerConfig>;
  startSync?: boolean;
  /** Test-only: 0 asks the OS for a free loopback port for the sync scaffold. */
  syncPort?: number;
  forceFallbackDeviceSecret?: boolean;
}

export async function startServer(opts: StartOptions = {}): Promise<ThingsServer> {
  const config: ServerConfig = { ...loadConfig(), ...opts.config };
  const core = Core.open({
    dataDir: config.dataDir,
    forceFallbackDeviceSecret: opts.forceFallbackDeviceSecret,
  });
  const session = new Session(core, config.autoLockMs);
  const api = buildApi({ core, session, config });

  const server = createServer(async (req, res) => {
    try {
      // DNS-rebinding guard. A hostile page that resolves its own name to
      // 127.0.0.1 still cannot talk to this service.
      if (!isAllowedHostHeader(req.headers.host)) {
        res.writeHead(403, { 'content-type': 'text/plain' });
        res.end('Things only answers to localhost.');
        return;
      }

      const url = new URL(req.url ?? '/', `http://${LOOPBACK_HOST}`);
      const path = url.pathname;

      if (!path.startsWith('/api/')) {
        if (!serveStatic(config.webRoot, path, res)) {
          const body = missingBuildPage();
          res.writeHead(503, { 'content-type': 'text/html; charset=utf-8', 'content-length': String(Buffer.byteLength(body)) });
          res.end(body);
        }
        return;
      }

      const method = req.method ?? 'GET';
      const matched = api.match(method, path);
      if (!matched) {
        json(res, 404, { error: 'No such endpoint' });
        return;
      }

      // Object bytes may also be authorised by the scoped, HttpOnly cookie:
      // an <img> tag cannot send an Authorization header. GET only, and only
      // under /api/objects — see Session.authorizeObjectCookie.
      const cookieOk =
        method === 'GET' && path.startsWith('/api/objects/') && session.authorizeObjectCookie(req.headers.cookie);

      if (!PUBLIC_ROUTES.has(`${method} ${path}`) && !cookieOk && !session.authorize(req.headers.authorization)) {
        json(res, session.locked ? 423 : 401, {
          error: session.locked ? 'Things is locked.' : 'Unauthorized',
          locked: session.locked,
        });
        return;
      }

      const ctx = makeCtx(req, res, path, url.searchParams, matched.params);
      await matched.handler(ctx);
      if (!res.writableEnded) json(res, 204, null);
    } catch (err) {
      const status = err instanceof HttpError ? err.status : 500;
      const message = err instanceof Error ? err.message : 'Unexpected error';
      if (status >= 500) console.error('[things]', err);
      if (!res.writableEnded) json(res, status, { error: message });
    }
  });

  const port = opts.port ?? WEB_PORT;
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    // The host is a constant that goes through the boundary check. There is no
    // configuration path that reaches this call with anything else.
    server.listen({ host: assertLoopback(LOOPBACK_HOST), port }, () => resolve());
  });

  let sync: SyncScaffold | null = null;
  if (opts.startSync !== false) {
    try {
      sync = await startSyncListener(core, opts.syncPort);
    } catch (e) {
      console.warn('[things] sync listener unavailable:', (e as Error).message);
    }
  }

  const address = server.address();
  const actualPort = typeof address === 'object' && address ? address.port : port;

  return {
    server,
    core,
    session,
    config,
    port: actualPort,
    sync,
    async close() {
      session.dispose();
      await new Promise<void>((done) => server.close(() => done()));
      if (sync) await sync.close();
      core.close();
    },
  };
}

function json(res: import('node:http').ServerResponse, status: number, data: unknown): void {
  const buf = Buffer.from(JSON.stringify(data ?? null));
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': String(buf.length),
    'x-content-type-options': 'nosniff',
  });
  res.end(buf);
}
