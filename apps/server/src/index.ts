import { startServer } from './server.ts';
import { LOOPBACK_HOST, WEB_PORT, SYNC_PORT } from './net.ts';

const server = await startServer();

console.log('');
console.log('  Things');
console.log(`  Web      http://localhost:${server.port}`);
console.log(`  Sync     ${server.sync ? `http://${LOOPBACK_HOST}:${SYNC_PORT} (scaffold — M7)` : 'unavailable'}`);
console.log(`  Data     ${server.config.dataDir}`);
console.log(`  Bound    ${LOOPBACK_HOST} only — never the LAN (docs/02-SECURITY.md §7)`);
if (server.port !== WEB_PORT) console.log(`  Note     port ${WEB_PORT} was unavailable`);
console.log('');

for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.on(signal, () => {
    void server.close().then(() => process.exit(0));
  });
}
