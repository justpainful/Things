import type { Db } from './db.ts';
import type { Registry } from './registry.ts';
import type { Hlc } from './hlc.ts';
import type { Oplog } from './oplog.ts';
import type { Keyring } from './crypto/keyring.ts';
import type { ObjectStore } from './objectStore.ts';

/** Everything a repository needs. Assembled once by `Core`. */
export interface CoreContext {
  db: Db;
  registry: Registry;
  deviceId: string;
  hlc: Hlc;
  oplog: Oplog;
  keyring: Keyring;
  objects: ObjectStore;
  now: () => string;
}
