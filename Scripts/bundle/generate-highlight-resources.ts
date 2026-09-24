// Bundles Shiki's grammars and themes (plus the Pierre themes) as JSON
// resources for SwiffsHighlight.
//
// Usage:
//   SHIKI_MODULES=/path/to/node_modules PIERRE_DIR=/path/to/pierre \
//     bun Scripts/bundle/generate-highlight-resources.ts
//
// SHIKI_MODULES must contain `shiki@4.4.1` (the version @pierre/diffs uses).
import { mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const SHIKI_MODULES = process.env.SHIKI_MODULES!;
const PIERRE_DIR = process.env.PIERRE_DIR!;
const OUT = join(import.meta.dir, '../../Sources/SwiffsHighlight/Resources');

const { bundledLanguagesInfo, bundledThemesInfo } = await import(join(SHIKI_MODULES, 'shiki/dist/index.mjs'));

rmSync(join(OUT, 'Languages'), { recursive: true, force: true });
rmSync(join(OUT, 'Themes'), { recursive: true, force: true });
mkdirSync(join(OUT, 'Languages'), { recursive: true });
mkdirSync(join(OUT, 'Themes'), { recursive: true });

const written = new Set<string>();
const languages: any[] = [];
for (const info of bundledLanguagesInfo) {
  const registrations: any[] = (await info.import()).default;
  const load: string[] = [];
  for (const registration of registrations) {
    load.push(registration.name);
    if (written.has(registration.name)) continue;
    written.add(registration.name);
    const copy: any = { ...registration };
    if (copy.injections) {
      copy.__swiffsInjectionKeys = Object.keys(copy.injections);
    }
    writeFileSync(join(OUT, 'Languages', `${registration.name}.json`), JSON.stringify(copy));
  }
  languages.push({ id: info.id, name: info.name, aliases: info.aliases ?? [], load });
}
writeFileSync(join(OUT, 'Languages', 'index.json'), JSON.stringify(languages, null, 1));

const themes: any[] = [];
for (const info of bundledThemesInfo) {
  const theme = (await info.import()).default;
  writeFileSync(join(OUT, 'Themes', `${info.id}.json`), JSON.stringify(theme));
  themes.push({ id: info.id, displayName: info.displayName, type: info.type });
}
for (const file of readdirSync(join(PIERRE_DIR, 'packages/theme/themes')).sort()) {
  if (!file.endsWith('.json')) continue;
  const theme = JSON.parse(readFileSync(join(PIERRE_DIR, 'packages/theme/themes', file), 'utf8'));
  writeFileSync(join(OUT, 'Themes', file), JSON.stringify(theme));
  themes.unshift({ id: theme.name, displayName: theme.displayName, type: theme.type });
}
writeFileSync(join(OUT, 'Themes', 'index.json'), JSON.stringify(themes, null, 1));
console.log(`languages=${languages.length} grammarFiles=${written.size} themes=${themes.length}`);
