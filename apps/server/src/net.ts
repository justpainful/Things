import { networkInterfaces } from 'node:os';

/**
 * The loopback boundary — docs/02-SECURITY.md §7.
 *
 * "The web UI binds 127.0.0.1 only, port 6767. It is never reachable from the
 * LAN. **This is enforced in code, not configuration**, and covered by a test."
 *
 * So there is no host option, no environment variable, and no config file key
 * that can widen it. `LOOPBACK_HOST` is a constant, and `assertLoopback()` is
 * called on the way into `listen()` so that even a future refactor that starts
 * threading a host through has to go through this check.
 */

export const LOOPBACK_HOST = '127.0.0.1';
export const WEB_PORT = 6767;
export const SYNC_PORT = 6768;

const ALLOWED_HOSTS = new Set(['127.0.0.1', '::1', 'localhost']);

export class NetworkBoundaryError extends Error {
  constructor(host: string) {
    super(
      `Refusing to listen on "${host}". The Things web service binds loopback only ` +
        `(docs/02-SECURITY.md §7). This is a security boundary, not a setting.`,
    );
    this.name = 'NetworkBoundaryError';
  }
}

export function isLoopbackHost(host: string | undefined | null): boolean {
  if (!host) return false; // undefined means "all interfaces" in node:net — never allowed
  return ALLOWED_HOSTS.has(host.trim().toLowerCase());
}

export function assertLoopback(host: string | undefined | null): string {
  if (!isLoopbackHost(host)) throw new NetworkBoundaryError(String(host));
  return host as string;
}

/**
 * Second line of defence: reject a request whose Host header is not loopback.
 * Stops DNS rebinding, where a hostile page resolves its own domain to
 * 127.0.0.1 and then talks to this server from the user's browser.
 */
export function isAllowedHostHeader(hostHeader: string | undefined): boolean {
  if (!hostHeader) return false;
  const withoutPort = hostHeader.replace(/:\d+$/, '').replace(/^\[|\]$/g, '').toLowerCase();
  return ALLOWED_HOSTS.has(withoutPort);
}

/** Every non-internal address on this machine — what the boundary test probes. */
export function lanAddresses(): string[] {
  const out: string[] = [];
  for (const list of Object.values(networkInterfaces())) {
    for (const iface of list ?? []) {
      if (!iface.internal && iface.family === 'IPv4') out.push(iface.address);
    }
  }
  return out;
}
