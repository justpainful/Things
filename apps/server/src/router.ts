import type { IncomingMessage, ServerResponse } from 'node:http';

export interface Ctx {
  req: IncomingMessage;
  res: ServerResponse;
  method: string;
  path: string;
  params: Record<string, string>;
  query: URLSearchParams;
  body(): Promise<Buffer>;
  json<T = unknown>(): Promise<T>;
  send(status: number, body: string | Buffer, headers?: Record<string, string>): void;
  sendJson(status: number, data: unknown, headers?: Record<string, string>): void;
  sendBytes(status: number, bytes: Buffer, contentType: string, headers?: Record<string, string>): void;
}

export type Handler = (ctx: Ctx) => unknown | Promise<unknown>;

interface Route {
  method: string;
  segments: string[];
  handler: Handler;
}

export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export const badRequest = (m: string) => new HttpError(400, m);
export const notFound = (m = 'Not found') => new HttpError(404, m);
export const locked = () => new HttpError(423, 'Things is locked.');
export const unauthorized = () => new HttpError(401, 'Unauthorized');

/** 1 MiB is generous for JSON; object uploads use their own limit. */
const MAX_JSON_BYTES = 1024 * 1024;
const MAX_UPLOAD_BYTES = 512 * 1024 * 1024;

export class Router {
  private routes: Route[] = [];

  add(method: string, pattern: string, handler: Handler): this {
    this.routes.push({ method, segments: pattern.split('/').filter(Boolean), handler });
    return this;
  }

  get = (p: string, h: Handler) => this.add('GET', p, h);
  post = (p: string, h: Handler) => this.add('POST', p, h);
  patch = (p: string, h: Handler) => this.add('PATCH', p, h);
  delete = (p: string, h: Handler) => this.add('DELETE', p, h);

  match(method: string, path: string): { handler: Handler; params: Record<string, string> } | null {
    const parts = path.split('/').filter(Boolean);
    for (const route of this.routes) {
      if (route.method !== method) continue;
      if (route.segments.length !== parts.length) continue;
      const params: Record<string, string> = {};
      let ok = true;
      for (let i = 0; i < parts.length; i++) {
        const seg = route.segments[i];
        if (seg.startsWith(':')) params[seg.slice(1)] = decodeURIComponent(parts[i]);
        else if (seg !== parts[i]) {
          ok = false;
          break;
        }
      }
      if (ok) return { handler: route.handler, params };
    }
    return null;
  }
}

export function makeCtx(
  req: IncomingMessage,
  res: ServerResponse,
  path: string,
  query: URLSearchParams,
  params: Record<string, string>,
): Ctx {
  let cached: Buffer | null = null;

  const send = (status: number, body: string | Buffer, headers: Record<string, string> = {}) => {
    const buf = Buffer.isBuffer(body) ? body : Buffer.from(body, 'utf8');
    res.writeHead(status, {
      'content-length': String(buf.length),
      // Nothing here is ever meant to be embedded, framed, or sniffed.
      'x-content-type-options': 'nosniff',
      'referrer-policy': 'no-referrer',
      ...headers,
    });
    res.end(buf);
  };

  return {
    req,
    res,
    method: req.method ?? 'GET',
    path,
    params,
    query,
    async body() {
      if (cached) return cached;
      const limit = path.startsWith('/api/objects') ? MAX_UPLOAD_BYTES : MAX_JSON_BYTES;
      const chunks: Buffer[] = [];
      let total = 0;
      for await (const chunk of req) {
        total += (chunk as Buffer).length;
        if (total > limit) throw new HttpError(413, 'Payload too large');
        chunks.push(chunk as Buffer);
      }
      cached = Buffer.concat(chunks);
      return cached;
    },
    async json<T>() {
      const raw = await this.body();
      if (raw.length === 0) return {} as T;
      try {
        return JSON.parse(raw.toString('utf8')) as T;
      } catch {
        throw badRequest('Invalid JSON');
      }
    },
    send,
    sendJson(status, data, headers = {}) {
      send(status, JSON.stringify(data ?? null), {
        'content-type': 'application/json; charset=utf-8',
        ...headers,
      });
    },
    sendBytes(status, bytes, contentType, headers = {}) {
      send(status, bytes, { 'content-type': contentType, ...headers });
    },
  };
}
