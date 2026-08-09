import { existsSync, statSync } from 'node:fs';
import type { CoreContext } from '../context.ts';
import { createEntity, updateEntity } from '../mutate.ts';
import { uuidv7, nowIso } from '../ids.ts';
import type { Device, FileRef, Platform } from '../types.ts';

/**
 * Device-aware paths.
 *
 * `D:\Servers\BeamNG\Server1` is meaningless without knowing *which machine*.
 * One table serves both the File Path field kind and the "reference the
 * original file" attachment mode, because they are the same idea — and the
 * behaviour falls out: on the owning device the action is Open in Explorer,
 * elsewhere the UI shows the device name, the path, and Copy Path.
 */

export class FileRefRepo {
  private ctx: CoreContext;

  constructor(ctx: CoreContext) {
    this.ctx = ctx;
  }

  get(id: string): FileRef | undefined {
    return this.ctx.db.get<FileRef>('SELECT * FROM file_ref WHERE id = ?', [id]);
  }

  create(input: { deviceId?: string; path: string; isDirectory?: boolean }): FileRef {
    const id = uuidv7();
    const deviceId = input.deviceId ?? this.ctx.deviceId;
    let size: number | null = null;
    let mtime: string | null = null;
    let status: FileRef['status'] = 'unknown';
    let isDirectory = input.isDirectory ?? false;

    if (deviceId === this.ctx.deviceId) {
      try {
        const st = statSync(input.path);
        size = st.isFile() ? st.size : null;
        mtime = new Date(st.mtimeMs).toISOString();
        isDirectory = st.isDirectory();
        status = 'present';
      } catch {
        status = 'missing';
      }
    }

    createEntity(this.ctx, 'file_ref', id, {
      device_id: deviceId,
      path: input.path,
      is_directory: isDirectory ? 1 : 0,
      size_at_link: size,
      mtime_at_link: mtime,
      content_hash: null,
      last_seen_at: status === 'present' ? nowIso() : null,
      status,
    });
    return this.get(id) as FileRef;
  }

  /** Re-stat every reference owned by this device. Populates Missing Files. */
  refreshLocal(): { present: number; missing: number } {
    const refs = this.ctx.db.all<FileRef>('SELECT * FROM file_ref WHERE device_id = ?', [this.ctx.deviceId]);
    let present = 0;
    let missing = 0;
    for (const ref of refs) {
      const ok = existsSync(ref.path);
      if (ok) present++;
      else missing++;
      updateEntity(this.ctx, 'file_ref', ref.id, {
        status: ok ? 'present' : 'missing',
        last_seen_at: ok ? nowIso() : ref.last_seen_at,
      });
    }
    return { present, missing };
  }

  missing(): FileRef[] {
    return this.ctx.db.all<FileRef>(`SELECT * FROM file_ref WHERE status = 'missing'`);
  }
}

export class DeviceRepo {
  private ctx: CoreContext;

  constructor(ctx: CoreContext) {
    this.ctx = ctx;
  }

  list(): Device[] {
    return this.ctx.db.all<Device>('SELECT * FROM device ORDER BY is_self DESC, name');
  }

  get(id: string): Device | undefined {
    return this.ctx.db.get<Device>('SELECT * FROM device WHERE id = ?', [id]);
  }

  self(): Device | undefined {
    return this.ctx.db.get<Device>('SELECT * FROM device WHERE is_self = 1');
  }

  ensureSelf(id: string, name: string, platform: Platform): Device {
    const existing = this.get(id);
    if (existing) return existing;
    this.ctx.db.run(
      'INSERT INTO device (id, name, platform, is_self, last_seen_at) VALUES (?,?,?,1,?)',
      [id, name, platform, nowIso()],
    );
    return this.get(id) as Device;
  }
}
