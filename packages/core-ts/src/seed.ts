import type { Core } from './core.ts';

/**
 * Demo dataset.
 *
 * docs/02-SECURITY.md §8: seed data is **obviously fictional** — no real
 * domains (everything is under `.example` / `.invalid`, which are reserved by
 * RFC 2606 and can never resolve), no plausible-looking keys, and every secret
 * literally says it is not a real secret. A screenshot of this attached to a
 * public CI run discloses nothing.
 *
 * It is also deliberately awkward: a 60-character title, a Thing with many
 * fields, an empty Thing, a locked Thing. Layout breaks live in the long tail,
 * and the seed exists to force them rather than flatter the design.
 */

const FAKE_SECRET = 'demo-value-not-a-real-secret';

export interface SeedResult {
  things: number;
  collections: number;
}

export function seedDemoData(core: Core): SeedResult {
  if (core.db.meta('seed_marker')) return { things: 0, collections: 0 };

  const out = core.db.transaction(() => {
    const dev = core.collections.create({
      name: 'Development',
      iconJson: JSON.stringify({ type: 'symbol', value: 'hammer' }),
    });
    const home = core.collections.create({
      name: 'Home Lab',
      iconJson: JSON.stringify({ type: 'symbol', value: 'server.rack' }),
    });
    const media = core.collections.create({
      name: 'Media',
      iconJson: JSON.stringify({ type: 'symbol', value: 'photo.on.rectangle' }),
    });

    // 1 — a Thing that is an account, a link and a note at once. The whole
    //     premise of the app in one row.
    const registrar = core.things.create({
      title: 'Example Registrar',
      iconJson: JSON.stringify({ type: 'symbol', value: 'globe' }),
      isPinned: true,
    });
    core.fields.create({ thingId: registrar.id, variant: 'website', label: 'Website', value: { kind: 'text', value: 'https://registrar.example/' } });
    core.fields.create({ thingId: registrar.id, variant: 'email', label: 'Email', value: { kind: 'text', value: 'demo.user@example.com' } });
    core.fields.create({ thingId: registrar.id, variant: 'username', label: 'Username', value: { kind: 'text', value: 'demo.user' } });
    core.fields.create({ thingId: registrar.id, variant: 'password', label: 'Main account password', value: { kind: 'secret', value: FAKE_SECRET } });
    core.fields.create({ thingId: registrar.id, variant: 'apiKey', label: 'API key', value: { kind: 'secret', value: FAKE_SECRET } });
    core.fields.create({
      thingId: registrar.id,
      variant: 'note',
      label: 'Notes',
      value: {
        kind: 'json',
        value: { type: 'doc', content: [{ type: 'paragraph', text: 'Renewal is annual. Billing contact is the shared mailbox.' }] },
      },
    });
    core.tags.attach(registrar.id, 'infrastructure');
    core.tags.attach(registrar.id, 'billing');
    core.collections.add(dev.id, registrar.id);

    // 2 — a project, with sections, a repo link and a device-scoped path.
    const project = core.things.create({
      title: 'Sample Project — a deliberately long title used to test truncation',
      iconJson: JSON.stringify({ type: 'symbol', value: 'hammer' }),
    });
    const links = core.sections.create(project.id, 'Links');
    const local = core.sections.create(project.id, 'On This Machine');
    core.fields.create({ thingId: project.id, sectionId: links.id, variant: 'github', label: 'Repository', value: { kind: 'text', value: 'https://github.example/demo/sample-project' } });
    core.fields.create({ thingId: project.id, sectionId: links.id, variant: 'website', label: 'Staging', value: { kind: 'text', value: 'https://staging.sample.invalid/' } });
    core.fields.create({ thingId: project.id, sectionId: links.id, variant: 'relation', label: 'Registrar', value: { kind: 'text', value: registrar.id } });
    const ref = core.fileRefs.create({ path: 'D:\\Demo\\SampleProject', isDirectory: true });
    core.fields.create({ thingId: project.id, sectionId: local.id, variant: 'folder', label: 'Working folder', value: { kind: 'fileRef', id: ref.id } });
    core.fields.create({ thingId: project.id, sectionId: local.id, variant: 'command', label: 'Run', value: { kind: 'text', value: 'npm run dev' } });
    core.tags.attach(project.id, 'active');
    core.collections.add(dev.id, project.id);

    // 3 — a server, the "many fields" stress case.
    const server = core.newFromTemplate('server', 'Demo Server');
    const serverFields = core.fields.forThing(server.id);
    const byLabel = new Map(serverFields.map((f) => [f.label, f]));
    setIf(core, byLabel.get('IP')?.id, { kind: 'text', value: '198.51.100.42' });
    setIf(core, byLabel.get('Port')?.id, { kind: 'text', value: '25565' });
    setIf(core, byLabel.get('Username')?.id, { kind: 'text', value: 'operator' });
    setIf(core, byLabel.get('Password')?.id, { kind: 'secret', value: FAKE_SECRET });
    for (let i = 1; i <= 18; i++) {
      core.fields.create({
        thingId: server.id,
        variant: 'plain',
        label: `Extra setting ${i}`,
        value: { kind: 'text', value: `value-${i}` },
      });
    }
    core.tags.attach(server.id, 'infrastructure');
    core.collections.add(home.id, server.id);

    // 4 — a person.
    const person = core.newFromTemplate('person', 'Alex Placeholder');
    core.tags.attach(person.id, 'people');

    // 5 — a locked Thing. Contributes nothing to search while locked.
    const locked = core.things.create({
      title: 'Private Records',
      iconJson: JSON.stringify({ type: 'symbol', value: 'lock' }),
    });
    core.fields.create({ thingId: locked.id, variant: 'secret', label: 'Recovery phrase', value: { kind: 'secret', value: FAKE_SECRET } });
    core.things.update(locked.id, { is_locked: true });

    // 6 — an empty Thing, for the empty state.
    core.things.create({ title: 'Untitled', iconJson: JSON.stringify({ type: 'auto' }) });

    // 7 — a media Thing with an inline generated image, so the gallery has
    //     something in it without shipping a binary in the repo.
    const gallery = core.things.create({
      title: 'Placeholder Artwork',
      iconJson: JSON.stringify({ type: 'symbol', value: 'photo' }),
    });
    for (const [i, colour] of ['#3b6ea5', '#a5643b', '#4d8f6a'].entries()) {
      const svg = Buffer.from(placeholderSvg(colour, `Placeholder ${i + 1}`), 'utf8');
      const put = core.objects.put(svg, { mimeType: 'image/svg+xml', width: 640, height: 400 });
      const f = core.fields.create({ thingId: gallery.id, variant: 'image', label: `Placeholder ${i + 1}` });
      core.fields.setValue(f.id, { kind: 'object', hash: put.hash });
    }
    core.collections.add(media.id, gallery.id);
    core.tags.attach(gallery.id, 'artwork');

    core.ensureSmartViews();
    core.db.setMeta('seed_marker', new Date().toISOString());

    return { things: 7, collections: 3 };
  });

  core.reindex();
  core.objects.recount();
  return out;
}

function setIf(core: Core, id: string | undefined, value: Parameters<Core['fields']['setValue']>[1]): void {
  if (id) core.fields.setValue(id, value);
}

function placeholderSvg(colour: string, label: string): string {
  return [
    '<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">',
    `<rect width="640" height="400" fill="${colour}"/>`,
    '<rect x="24" y="24" width="592" height="352" fill="none" stroke="rgba(255,255,255,.35)" stroke-width="2"/>',
    `<text x="320" y="210" text-anchor="middle" font-family="system-ui, sans-serif" font-size="34" fill="#fff">${label}</text>`,
    '</svg>',
  ].join('');
}
